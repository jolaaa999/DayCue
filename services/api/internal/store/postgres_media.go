package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/jolaaa999/DayCue/services/api/internal/media"
)

// 让 *Postgres 同时充当 media.Catalog。
//
// 之所以放在 store 而不是 media：media 包不该知道 SQL，而 media_object 表本来就属于
// 服务端存储层。字节流仍由 media.Store 负责，这里只管元数据——将来换对象存储时
// 只需要替换"字节那一半"。
var _ media.Catalog = (*Postgres)(nil)

func scanMediaObject(s rowScanner) (media.Object, error) {
	var o media.Object
	if err := s.Scan(&o.ID, &o.UserID, &o.OwnerType, &o.OwnerID, &o.ContentType,
		&o.ByteSize, &o.SHA256, &o.StorageKey, &o.CreatedAt); err != nil {
		return media.Object{}, err
	}
	return o, nil
}

// Insert 登记一份媒体元数据。
func (p *Postgres) Insert(ctx context.Context, o media.Object) error {
	createdAt := o.CreatedAt
	if createdAt.IsZero() {
		createdAt = p.now()
	}
	if _, err := p.db.ExecContext(ctx, sqlMediaInsert,
		o.ID, o.UserID, o.OwnerType, o.OwnerID, o.ContentType,
		o.ByteSize, o.SHA256, o.StorageKey, createdAt.UTC()); err != nil {
		return fmt.Errorf("store: 登记媒体失败: %w", err)
	}
	return nil
}

// ByID 按 (userID, id) 查媒体元数据；别人的对象返回 media.ErrNotFound。
func (p *Postgres) ByID(ctx context.Context, userID, id string) (media.Object, error) {
	o, err := scanMediaObject(p.db.QueryRowContext(ctx, sqlMediaByID, userID, id))
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// 与 media 包的约定一致：不存在与不属于本用户返回同一个错误，不泄漏存在性。
			return media.Object{}, media.ErrNotFound
		}
		return media.Object{}, fmt.Errorf("store: 查询媒体失败: %w", err)
	}
	return o, nil
}

// ByOwner 列出某个实体名下的媒体元数据。
func (p *Postgres) ByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]media.Object, error) {
	rows, err := p.db.QueryContext(ctx, sqlMediaByOwner, userID, ownerType, ownerID)
	if err != nil {
		return nil, fmt.Errorf("store: 查询媒体列表失败: %w", err)
	}
	defer rows.Close()
	var out []media.Object
	for rows.Next() {
		o, err := scanMediaObject(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描媒体失败: %w", err)
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历媒体失败: %w", err)
	}
	return out, nil
}

// Delete 删除媒体元数据；删不到返回 media.ErrNotFound。
func (p *Postgres) Delete(ctx context.Context, userID, id string) error {
	res, err := p.db.ExecContext(ctx, sqlMediaDelete, userID, id)
	if err != nil {
		return fmt.Errorf("store: 删除媒体失败: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("store: 读取删除结果失败: %w", err)
	}
	if n == 0 {
		return media.ErrNotFound
	}
	return nil
}

// DeleteByOwner 删除某个实体名下的全部媒体元数据，并返回被删对象。
//
// 用 DELETE ... RETURNING 一条语句同时完成"删"和"取回存储键"：
// 分成"先查后删"会在两步之间把新写入的对象漏掉，留下无人认领的孤儿文件。
func (p *Postgres) DeleteByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]media.Object, error) {
	rows, err := p.db.QueryContext(ctx, sqlMediaDeleteByOwner, userID, ownerType, ownerID)
	if err != nil {
		return nil, fmt.Errorf("store: 按属主删除媒体失败: %w", err)
	}
	defer rows.Close()
	var out []media.Object
	for rows.Next() {
		o, err := scanMediaObject(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 扫描媒体失败: %w", err)
		}
		out = append(out, o)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 遍历媒体失败: %w", err)
	}
	return out, nil
}

// DeleteAllForUser 删除该用户的全部媒体元数据，并返回被删对象以便调用方清盘。
//
// 账号注销必须用它：按 (ownerType, ownerID) 删需要先枚举用户有多少种属主，
// 做不到"清干净"，而注销的语义就是一点都不能剩。
func (p *Postgres) DeleteAllForUser(ctx context.Context, userID string) ([]media.Object, error) {
	rows, err := p.db.QueryContext(ctx,
		`DELETE FROM media_object WHERE user_id = $1
		 RETURNING id, user_id, owner_type, owner_id, content_type, byte_size, sha256, storage_key, created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []media.Object
	for rows.Next() {
		o, err := scanMediaObject(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}
