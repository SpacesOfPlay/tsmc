// Shared runtime values.

/** How a request was satisfied, for the access log. */
export enum Outcome {
  File = 'file',
  Markdown = 'markdown',
  Index = 'index',
  NotModified = 'not-modified',
  NotFound = 'not-found',
  Rejected = 'rejected',
  Failed = 'failed',
}
