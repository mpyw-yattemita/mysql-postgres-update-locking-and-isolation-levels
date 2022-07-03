CREATE TABLE products(
    id INTEGER PRIMARY KEY,
    remaining_amount INTEGER NOT NULL,
    referencing_amount_A INTEGER DEFAULT NULL,
    referencing_amount_B INTEGER DEFAULT NULL
);

INSERT INTO products(id, remaining_amount, referencing_amount_A, referencing_amount_B) VALUES (1, 1, NULL, NULL);
