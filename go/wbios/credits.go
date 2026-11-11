package wbios

// 账号积分查询：让 App 界面能看到每个账号还剩多少积分。
//
// 为什么不在 pool 里查：pool 里只有「签到时顺手写回」的余额（entry.credits），
// iOS 版调度器为了省电把签到排程的时点交给系统，界面打开时往往还是 0。
// 这里直接调上游 billing/meter（internal/upstream.UserResourceDetailed）取权威值，
// 并写回 pool（SetCreditsDetailed），顺带让选号权重也用上真实积分。

import (
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	"workbuddy2api/internal/auth"
	"workbuddy2api/internal/logfmt"
	"workbuddy2api/internal/upstream"
)

// creditRefreshInterval 后台余额刷新间隔。
// 与桌面版 config.schedule.balance_refresh_minutes 默认 5 分钟保持一致；
// 多 30 秒是为了避开整点签到任务抢带宽。
const creditRefreshInterval = 5*time.Minute + 30*time.Second

var (
	creditStopOnce sync.Once
	creditStopCh   chan struct{}
)

// startCreditRefresher 启动积分刷新协程（幂等；Stop 时停）。
func startCreditRefresher(ins *instance) {
	creditStopOnce = sync.Once{}
	creditStopCh = make(chan struct{})
	go func(ins *instance, stop <-chan struct{}) {
		// 首次稍等一下：让监听端口先就绪，避免和启动探测抢上游连接。
		select {
		case <-time.After(2 * time.Second):
		case <-stop:
			return
		}
		refreshAllCredits(ins)
		t := time.NewTicker(creditRefreshInterval)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				refreshAllCredits(ins)
			case <-stop:
				return
			}
		}
	}(ins, creditStopCh)
}

// RefreshCredits 立即刷新所有账号积分（界面下拉刷新/启动时调用）。
// 返回刷新成功的账号数；失败原因逐账号记在 status 的 credits_err 里。
// C 入口见 iosmain.WbRefreshCredits。
func RefreshCredits() int {
	mu.Lock()
	ins := inst
	mu.Unlock()
	if ins == nil {
		return 0
	}
	return refreshAllCredits(ins)
}

// refreshAllCredits 并发查询所有账号余额。返回成功条数。
//
// 并发上限 2：iOS 后台带宽/CPU 有限，且上游对短 RPC 有速率风控；
// 账号数一般个位数，串并混合意义不大。
func refreshAllCredits(ins *instance) int {
	if ins == nil || ins.app == nil || ins.app.Pool == nil || ins.app.Upstream == nil {
		return 0
	}
	auths, err := auth.LoadDir(ins.app.Cfg.AuthDir)
	if err != nil {
		log.Printf("[credits] 读取账号目录失败：%v", err)
		return 0
	}
	sem := make(chan struct{}, 2)
	var wg sync.WaitGroup
	var okCount int64
	var cntMu sync.Mutex
	for _, a := range auths {
		a := a
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			if refreshOneCredit(ins, a) {
				cntMu.Lock()
				okCount++
				cntMu.Unlock()
			}
		}()
	}
	wg.Wait()
	return int(okCount)
}

// refreshOneCredit 查询单账号余额并写回快照 + pool。返回是否成功。
func refreshOneCredit(ins *instance, a *auth.Auth) bool {
	credits, expiring, err := queryCredits(ins.app.Upstream, a, ins.app.Cfg.ExpiringSoonDur)
	now := time.Now().Unix()
	ins.creditsMu.Lock()
	ci := ins.credits[a.UID]
	if ci == nil {
		ci = &creditInfo{}
		ins.credits[a.UID] = ci
	}
	if err != nil {
		// 查询失败不清零：保留上次成功的数值，只记原因。
		ci.Err = humanCreditErr(err)
		ins.creditsMu.Unlock()
		log.Printf("[credits] %s 查询失败：%v", labelOf(a), err)
		return false
	}
	ci.Credits = credits
	ci.Expiring = expiring
	ci.At = now
	ci.Err = ""
	ins.creditsMu.Unlock()

	// 写回 pool：界面展示与选号权重共用同一份事实。
	if ins.app.Pool != nil {
		ins.app.Pool.SetCreditsDetailed(a.UID, credits, expiring)
	}
	return true
}

// queryCredits 取账号剩余积分（含快过期子集）。
// soon>0 时同时算「窗口内到期」的子集；多账号并发调用安全（每次新建请求）。
func queryCredits(c *upstream.Client, a *auth.Auth, soon time.Duration) (credits, expiring int64, err error) {
	if c == nil {
		return 0, 0, fmt.Errorf("上游客户端未初始化")
	}
	remain, buckets, err := c.UserResourceDetailed(a, soon)
	if err != nil {
		return 0, 0, err
	}
	return remain, buckets.Expiring, nil
}

// humanCreditErr 把上游错误翻成界面能看懂的一句话。
func humanCreditErr(err error) string {
	if err == nil {
		return ""
	}
	var uerr *upstream.Error
	if errors.As(err, &uerr) {
		switch uerr.Status {
		case 401, 403:
			return "凭证失效，请重新登录"
		case 429:
			return "查询过于频繁，稍后重试"
		}
		if uerr.Msg != "" {
			return fmt.Sprintf("HTTP %d：%s", uerr.Status, uerr.Msg)
		}
		return fmt.Sprintf("HTTP %d", uerr.Status)
	}
	return err.Error()
}

// labelOf 日志标签：昵称（空则 UID 前 8 位），与网关日志同口径。
func labelOf(a *auth.Auth) string {
	if a == nil {
		return "-"
	}
	return logfmt.Label(a.UID, a.Nickname)
}

// stopCreditRefresher 停止后台刷新。
func stopCreditRefresher() {
	if creditStopCh != nil {
		select {
		case <-creditStopCh:
		default:
			close(creditStopCh)
		}
	}
}
