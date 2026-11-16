package demo

// A case class.
case class User(name: String, age: Int)

object Main {
  def main(args: Array[String]): Unit = {
    val users = List(User("Ann", 42))
    val raw = """two
lines"""
    println(users.map(_.name).mkString(", ") + raw.length)
  }
}
