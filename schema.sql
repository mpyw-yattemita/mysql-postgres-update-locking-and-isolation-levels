CREATE TABLE products(
    id INTEGER PRIMARY KEY,
    remaining_amount INTEGER NOT NULL,
    referencing_amount_A INTEGER,
    referencing_amount_B INTEGER
);

INSERT INTO products(id, remaining_amount) VALUES (1, 1);
