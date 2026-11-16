module 0x1::counter {
    use std::signer;

    /// A counter.
    struct Counter has key { value: u64 }

    public entry fun create(account: &signer) {
        move_to(account, Counter { value: 0 }); // start
        let _ok = signer::address_of(account) != @0x0 && true;
    }
}
