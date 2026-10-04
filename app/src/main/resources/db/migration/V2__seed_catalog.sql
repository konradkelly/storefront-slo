-- The demo catalog. This used to be inserted by Catalog.run() on startup when the table was empty, which raced
-- when several replicas started at once (each saw an empty table and inserted its own copy). Flyway runs each
-- migration exactly once per database, and holds a lock while migrating, so replicas no longer race.
-- The initial_stock placeholder comes from storefront.restock-level (spring.flyway.placeholders in application.yml).
-- Flyway substitutes placeholders everywhere in the file, comments included, so it's only spelled out below.

INSERT INTO product (name, price_cents, stock) VALUES
    ('Trail Runner Shoes',     12999, ${initial_stock}),
    ('Rain Shell Jacket',      18950, ${initial_stock}),
    ('Insulated Water Bottle',  3495, ${initial_stock}),
    ('Daypack 22L',             8900, ${initial_stock}),
    ('Merino Wool Socks',       2295, ${initial_stock}),
    ('Headlamp',                4499, ${initial_stock}),
    ('Trekking Poles',         11995, ${initial_stock}),
    ('Camp Mug',                1899, ${initial_stock});
