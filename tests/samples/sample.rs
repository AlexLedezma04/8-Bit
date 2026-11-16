use std::collections::HashMap;

/// A counter.
#[derive(Debug)]
struct Counter { count: u32 }

fn main() {
    let mut map: HashMap<&str, u32> = HashMap::new();
    map.insert("a", 1); // first
    let c = Counter { count: 0 };
    let s = r#"raw "text""#;
    println!("{:?} {}", c, s);
}
