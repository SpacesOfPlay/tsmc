export const greeting = "hello";
export function repeat(s: string, n: number): string {
    let out = "";
    for (let i = 0; i < n; i++) out += s;
    return out;
}
