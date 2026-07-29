// `exports` is only an alias for module.exports until something reassigns it.
exports.before = 'kept';
module.exports = { after: 'wins' };
exports.stranded = 'lost';
