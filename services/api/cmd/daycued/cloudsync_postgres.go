//go:build postgres

package main

import (
	"context"
	"database/sql"
	"net/http"
	"strings"
	"time"

	// 驱动只出现在组装层：internal/store 保持零依赖，换驱动不用改业务代码。
	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/jolaaa999/DayCue/services/api/internal/api"
	"github.com/jolaaa999/DayCue/services/api/internal/authn"
	"github.com/jolaaa999/DayCue/services/api/internal/config"
	"github.com/jolaaa999/DayCue/services/api/internal/media"
	"github.com/jolaaa999/DayCue/services/api/internal/store"
	"github.com/jolaaa999/DayCue/services/api/internal/syncsvc"
)

// newCloudSyncHandler 在 postgres 构建下接通账号、设备、同步、媒体与导出端点。
//
// 说明：本文件只有在 -tags postgres 时才会被编译。默认构建下
// go build ./... / go vet ./... / go test ./... 都不会碰它，
// 因此本机（无驱动、可能无网络）仍能全绿。
func newCloudSyncHandler(cfg config.Config, srv *api.Server) (http.Handler, *store.Postgres, string, error) {
	if strings.TrimSpace(cfg.DatabaseURL) == "" {
		return nil, nil, "云同步未启用（未配置 DAYCUE_DATABASE_URL），客户端只走本地，功能不受影响", nil
	}

	db, err := sql.Open("pgx", cfg.DatabaseURL)
	if err != nil {
		return nil, nil, "", err
	}

	// 启动即迁移：把版本号与脚本放在同一个事务里执行，
	// 不会出现"脚本跑了但版本没记上"的中间态。
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := store.Migrate(ctx, db, time.Now); err != nil {
		return nil, nil, "", err
	}

	pg, err := store.NewPostgres(db, time.Now)
	if err != nil {
		return nil, nil, "", err
	}

	// *store.Postgres 同时实现了 media.Catalog，所以可以直接注入，
	// 媒体元数据与业务数据在同一套事务语义下。
	mediaStore, err := media.NewFS(cfg.MediaRoot, pg, cfg.MaxAudioBytes, time.Now)
	if err != nil {
		return nil, nil, "", err
	}

	issuer, err := authn.NewIssuer(cfg.TokenSecret, time.Now)
	if err != nil {
		return nil, nil, "", err
	}

	root, err := api.NewRootHandler(srv, api.AccountDeps{
		Users:  pg,
		Sync:   &syncsvc.Service{Sync: pg, Exporter: pg, Now: time.Now},
		Media:  mediaStore,
		Issuer: issuer,
		Now:    time.Now,
	})
	if err != nil {
		return nil, nil, "", err
	}
	return root, pg, "云同步已启用（账号 / 设备 / 增量同步 / 媒体 / 导出与注销）", nil
}
