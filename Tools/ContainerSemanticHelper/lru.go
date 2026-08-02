// Copyright © 2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

package main

import (
	"container/list"
	"sync"
)

type lruEntry[V any] struct {
	key    string
	value  V
	weight int
}

type lruCache[V any] struct {
	mu             sync.Mutex
	entries        map[string]*list.Element
	order          *list.List
	maximumEntries int
	maximumWeight  int
	weight         int
}

func newLRUCache[V any](maximumEntries, maximumWeight int) *lruCache[V] {
	return &lruCache[V]{
		entries:        make(map[string]*list.Element),
		order:          list.New(),
		maximumEntries: maximumEntries,
		maximumWeight:  maximumWeight,
	}
}

func (c *lruCache[V]) get(key string) (V, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	element, found := c.entries[key]
	if !found {
		var zero V
		return zero, false
	}
	c.order.MoveToFront(element)
	return element.Value.(*lruEntry[V]).value, true
}

func (c *lruCache[V]) put(key string, value V, weight int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if existing, found := c.entries[key]; found {
		entry := existing.Value.(*lruEntry[V])
		c.weight -= entry.weight
		entry.value = value
		entry.weight = weight
		c.weight += weight
		c.order.MoveToFront(existing)
	} else {
		entry := &lruEntry[V]{key: key, value: value, weight: weight}
		element := c.order.PushFront(entry)
		c.entries[key] = element
		c.weight += weight
	}
	for c.order.Len() > c.maximumEntries || c.weight > c.maximumWeight {
		oldest := c.order.Back()
		if oldest == nil {
			break
		}
		entry := oldest.Value.(*lruEntry[V])
		delete(c.entries, entry.key)
		c.weight -= entry.weight
		c.order.Remove(oldest)
	}
}

func (c *lruCache[V]) counts() (int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.order.Len(), c.weight
}
