// module-local state persists across requires (cache identity)
let n = 0;
exports.tick = () => ++n;
