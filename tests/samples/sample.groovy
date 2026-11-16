// A build script.
def greet(String name) {
    println "Hello, ${name}"
}

class Point { int x = 0; int y = 0 }

def text = '''two
lines'''
greet('world')
assert new Point().x == 0 && true
