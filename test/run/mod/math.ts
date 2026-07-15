export const PI = 3.14159;
export function add(a: number, b: number): number {
    return a + b;
}
export function mul(a: number, b: number): number {
    return a * b;
}
export default function identity<T>(x: T): T {
    return x;
}
