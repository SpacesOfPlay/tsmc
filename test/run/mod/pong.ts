import { ping } from "./ping";
export function pong(n: number): string {
    if (n <= 0) return "done";
    return "pong " + ping(n - 1);
}
