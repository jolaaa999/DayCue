//go:build !postgres

package main

import (
	"errors"
	"net/http"
	"strings"

	"github.com/jolaaa999/DayCue/services/api/internal/api"
	"github.com/jolaaa999/DayCue/services/api/internal/config"
)

// newCloudSyncHandler 在**未内置数据库驱动**的默认构建里做两件事。
//
// 为什么要有这个文件：账号/同步/媒体端点已经实现并有测试，但它们需要
// PostgreSQL 连接，而连接需要一个第三方驱动。模块目前坚持零第三方依赖
// （本机也可能无法 go get），所以把"要驱动的那条路"放进 //go:build postgres，
// 默认构建保持可编译、可测试。
//
// 行为约定：没配 DATABASE_URL 就是"云同步未启用"，服务照常启动；
// 配了却没用 postgres 标签构建，属于配置错误，直接拒绝启动 ——
// 悄悄降级成"没有云同步"会让用户以为数据同步了，实际没有。
func newCloudSyncHandler(cfg config.Config, _ *api.Server) (http.Handler, string, error) {
	if strings.TrimSpace(cfg.DatabaseURL) == "" {
		return nil, "云同步未启用（未配置 DAYCUE_DATABASE_URL），客户端只走本地，功能不受影响", nil
	}
	return nil, "", errors.New(
		"已配置 DAYCUE_DATABASE_URL，但本二进制未内置 PostgreSQL 驱动；" +
			"请先执行 go get github.com/jackc/pgx/v5，再用 go build -tags postgres 重新构建")
}
