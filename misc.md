Came up with another, slightly more elegant solution.

Instead of nasty function overloading, we could add an additional argument for `generatePath` - an array of addresses called `customPath`. If the array is empty, everything runs business as usual. If it's not empty, it will be used as `path`. Here is the [implementation of the new function](https://github.com/SimasG/offset-helper-backend/blob/flexible-path-2/contracts/OffsetHelper.sol#L612).

Positives:

- Clear & short (only ~60 additional lines of code)

Negatives:

- Adds additional `customPath` argument for every function that is built on `generatePath` (15, to be exact)
- Doesn't work under the current way we set `eligibleTokenAddresses`.
  Currently, we set `eligibleTokenAddresses` on contract deployment & do not allow swaps with tokens that aren't in this mapping. To be honest, I don't understand why we should specify swappable token addresses within `eligibleTokenAddresses`. If a dev wants to use a custom path but there's no/not enough liquidity in those pools, the transaction should just fail (might be wrong). Although adding BCT & NCT as "eligible" does seem to make sense because they're the only redeemables we support atm).

  Would love to add tests for these custom paths but I'm having trouble simulating non-existent liquidity pools. Would appreciate any help here!
