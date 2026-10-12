package media

import (
	"context"
	"sort"
	"sync"
)

// MemoryCatalog 是 Catalog 的内存实现，供测试与本地开发使用。
// 与 store.Memory 一样，它的价值在于让"越权读取""级联删除"这类规则
// 在没有数据库的机器上也能被真正验证。
type MemoryCatalog struct {
	mu   sync.RWMutex
	objs map[string]Object
}

// NewMemoryCatalog 构造内存目录。
func NewMemoryCatalog() *MemoryCatalog {
	return &MemoryCatalog{objs: map[string]Object{}}
}

func key(userID, id string) string { return userID + "|" + id }

func (c *MemoryCatalog) Insert(ctx context.Context, o Object) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.objs[key(o.UserID, o.ID)] = o
	return nil
}

func (c *MemoryCatalog) ByID(ctx context.Context, userID, id string) (Object, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	o, ok := c.objs[key(userID, id)]
	if !ok {
		return Object{}, ErrNotFound
	}
	return o, nil
}

func (c *MemoryCatalog) ByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	var out []Object
	for _, o := range c.objs {
		if o.UserID == userID && o.OwnerType == ownerType && o.OwnerID == ownerID {
			out = append(out, o)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (c *MemoryCatalog) Delete(ctx context.Context, userID, id string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	k := key(userID, id)
	if _, ok := c.objs[k]; !ok {
		return ErrNotFound
	}
	delete(c.objs, k)
	return nil
}

func (c *MemoryCatalog) DeleteByOwner(ctx context.Context, userID, ownerType, ownerID string) ([]Object, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var removed []Object
	for k, o := range c.objs {
		if o.UserID == userID && o.OwnerType == ownerType && o.OwnerID == ownerID {
			removed = append(removed, o)
			delete(c.objs, k)
		}
	}
	sort.Slice(removed, func(i, j int) bool { return removed[i].ID < removed[j].ID })
	return removed, nil
}

// DeleteAllForUser 删除该用户的全部对象并返回被删清单，供账号注销时一并清盘。
func (c *MemoryCatalog) DeleteAllForUser(ctx context.Context, userID string) ([]Object, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var removed []Object
	for k, o := range c.objs {
		if o.UserID == userID {
			removed = append(removed, o)
			delete(c.objs, k)
		}
	}
	sort.Slice(removed, func(i, j int) bool { return removed[i].ID < removed[j].ID })
	return removed, nil
}
