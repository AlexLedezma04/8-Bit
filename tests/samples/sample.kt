package demo

// A data class.
data class User(val name: String, val age: Int = 0)

fun main() {
    val user = User("Ann", 42)
    println("Hi ${user.name}")
    val raw = """
        two lines
    """
}
