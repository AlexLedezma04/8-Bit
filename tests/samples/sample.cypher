// Friends of a person.
MATCH (p:Person {name: 'Ann'})-[:KNOWS]->(f:Person)
WHERE f.age > 30 AND f.active = true
/* sort them */
RETURN f.name, count(*) AS total
ORDER BY total DESC
LIMIT $limit;
