// Types.
interface User {
  name: string;
  age?: number;
}

export function greet(user: User): string {
  const parts: Array<string> = [user.name];
  return `Hi ${parts.join(" ")}`; /* done */
}

type Id = string | number;
