// A component.
type user = {name: string, age: int}

let greet = (user: user) => {
  /* build */
  `Hello, ${user.name}`
}

let () = Js.log(greet({name: "Ann", age: 42}))
