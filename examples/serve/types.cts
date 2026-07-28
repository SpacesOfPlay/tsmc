// Shared runtime values.
//
// CommonJS TypeScript (.cts) throughout this example: `.ts` is treated as an ES
// module, and tsmc's ESM resolver does not search node_modules yet, so a `.ts`
// file cannot use an npm package. `.cts` is the Node-sanctioned CommonJS
// spelling and gets both. See README.md.
//
// Interfaces are declared in the file that uses them rather than imported,
// because `import type` would also mark the file as ESM.

/** How a request was satisfied, for the access log. */
enum Outcome {
  File = 'file',
  Markdown = 'markdown',
  Index = 'index',
  NotModified = 'not-modified',
  NotFound = 'not-found',
  Rejected = 'rejected',
  Failed = 'failed',
}

module.exports = { Outcome };
