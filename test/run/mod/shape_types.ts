export interface Shape { area(): number; }
export type Named = { name: string };
export function square(side: number): Shape { return { area: () => side * side }; }
