// Replacing module.exports wholesale is the usual way to export a function.
module.exports = function greet() { return 'hi'; };
module.exports.extra = 'attached';
