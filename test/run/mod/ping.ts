import { pong } from "./pong";
export function ping(n: number): string {
    if (n <= 0) return "done";
    return "ping " + pong(n - 1);
}
