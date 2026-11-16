// A contract.
access(all) contract Hello {
    access(all) let greeting: String

    /* set it */
    init() {
        self.greeting = "Hello, world"
    }

    access(all) fun hello(): String {
        return self.greeting
    }
}
