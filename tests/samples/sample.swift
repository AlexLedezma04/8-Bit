import Foundation

// A shape.
struct Circle {
    let radius: Double
    func area() -> Double { return .pi * radius * radius }
}

let c = Circle(radius: 2)
print("Area: \(c.area())", true, nil as Int?)
