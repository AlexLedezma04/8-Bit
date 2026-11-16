// A counter contract.
#[starknet::contract]
mod counter {
    #[storage]
    struct Storage {
        value: u128,
    }

    fn add(a: felt252, b: felt252) -> felt252 {
        let ok: bool = true;
        a + b
    }
}
