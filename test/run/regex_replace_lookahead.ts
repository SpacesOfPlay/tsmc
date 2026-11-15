// a zero-width match ahead of where the search began is taken once
console.log("1234567".replace(/\B(?=(\d{3})+(?!\d))/g, ","));
console.log("abc".replace(/(?=b)/g, "-"), "aaa".replace(/a*?/g, "-"), "abc".replace(/b*/g, "-"));
