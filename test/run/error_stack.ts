// error.stack call chain, cause, and VM-thrown errors. The absolute
// source path is stripped so the golden output is machine-independent.

function norm(stack: string): string {
    // "(C:/dir/error_stack.ts:2:3)" -> "(error_stack.ts:2:3)"
    return stack.replace(/\([^()]*[\/\\]/g, "(");
}

function inner(): void {
    throw new Error("boom");
}
function outer(): void {
    inner();
}
try {
    outer();
} catch (e) {
    console.log(norm((e as Error).stack));
}

// error.cause
const wrapped = new Error("wrap", { cause: new RangeError("root") });
console.log(wrapped.message, (wrapped as any).cause.constructor.name, (wrapped as any).cause instanceof Error);

// custom subclass keeps its own name/message and gets a stack
class AppError extends Error {
    constructor(m: string) {
        super(m);
        this.name = "AppError";
    }
}
try {
    throw new AppError("nope");
} catch (e) {
    const err = e as Error;
    console.log(err.name, err.message, err instanceof Error, typeof err.stack === "string");
}

// a VM-thrown TypeError still has a usable stack
try {
    const x: any = undefined;
    x.prop;
} catch (e) {
    const lines = (e as Error).stack.split("\n");
    console.log(lines[0], "| frames:", lines.length > 1);
}
