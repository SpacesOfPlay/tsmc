// A decoy beside expkg.ts. Loading it is the failure.
console.log("sibling pkgmain.ts loaded");
export default { pad: () => "sibling" };
