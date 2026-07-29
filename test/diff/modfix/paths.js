const path = require('path');
module.exports = {
  dirBase: path.basename(__dirname),
  fileBase: path.basename(__filename),
  moduleFileBase: path.basename(module.filename || ''),
  hasExports: typeof module.exports,
  loadedDuringLoad: module.loaded,
};
