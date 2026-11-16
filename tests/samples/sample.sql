-- Users.
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL
);

/* Find them. */
select count(*) from users where name like 'A%' and id > 10;
