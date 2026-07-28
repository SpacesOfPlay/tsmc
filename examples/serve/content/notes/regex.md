---
title: Bounded repeats
---

# Bounded repeats

A bounded repeat `{n,m}` emits its optional copies *nested* rather than as a
sequence, so a failing tail explores `m` paths instead of `C(m, length)`:

```js
/^(?:.{1,50}@)?/.exec('a.com')   // "" — matches empty
```

| bound | subject length | paths (sequential) |
| ----- | -------------- | ------------------ |
| 49    | 5              | 1,906,884          |
| 21    | 10             | 352,716            |
