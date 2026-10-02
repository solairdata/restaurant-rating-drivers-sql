/* =====================================================================
   WHAT DRIVES RESTAURANT RATINGS? - A SQL MARKET ANALYSIS (PostgreSQL)
   ---------------------------------------------------------------------
   Business question:
   What separates highly rated restaurants from the rest -
   price level, online delivery, table booking, cuisine or city?

   Dataset: Zomato Restaurants Data (Kaggle), 9,551 restaurants, 15 countries
   Note:    rating drivers are analysed on Delhi NCR only - see check 1.8
   Author:  Ana Knežević Stojanović
   ===================================================================== */


-- =====================================================================
-- PART 0: SETUP
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS market_analysis;

DROP TABLE IF EXISTS market_analysis.restaurants CASCADE;

CREATE TABLE market_analysis.restaurants (
    restaurant_id        INTEGER PRIMARY KEY,
    restaurant_name      VARCHAR(255),
    country_code         INTEGER,
    city                 VARCHAR(100),
    address              TEXT,
    locality             VARCHAR(255),
    locality_verbose     VARCHAR(255),
    longitude            DECIMAL,
    latitude             DECIMAL,
    cuisines             TEXT,
    average_cost_for_two INTEGER,
    currency             VARCHAR(50),
    has_table_booking    VARCHAR(20),
    has_online_delivery  VARCHAR(20),
    is_delivering_now    VARCHAR(20),
    switch_to_order_menu VARCHAR(20),
    price_range          INTEGER,
    aggregate_rating     DECIMAL,
    rating_color         VARCHAR(50),
    rating_text          VARCHAR(50),
    votes                INTEGER
);

-- Load the CSV (change the path to where the file is saved on your machine).
-- In pgAdmin you can also use: right-click the table > Import/Export Data.
-- In psql, use \copy instead of COPY if the file is on your local computer.
COPY market_analysis.restaurants
FROM '/path/to/Zomato_Restaurant_Dataset.csv'
WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

-- The dataset stores only country codes, not country names.
-- This query lists the currency and cities for each code, which is enough
-- to identify the country (e.g. Doha -> Qatar). Where several countries use
-- "Dollar($)" (codes 14, 37, 184, 216), the cities decide.
-- Note: code 162 has cities in the Philippines but the currency is wrongly
-- recorded as "Botswana Pula" - an error in the source data.
SELECT country_code,
       currency,
       COUNT(*)                         AS number_of_restaurants,
       STRING_AGG(DISTINCT city, ', ')  AS cities
FROM market_analysis.restaurants
GROUP BY country_code, currency
ORDER BY country_code;

-- Based on the result above, a small lookup table with country names is added.
DROP TABLE IF EXISTS market_analysis.countries CASCADE;

CREATE TABLE market_analysis.countries (
    country_code INTEGER PRIMARY KEY,
    country_name VARCHAR(50)
);

INSERT INTO market_analysis.countries (country_code, country_name) VALUES
    (1,   'India'),
    (14,  'Australia'),
    (30,  'Brazil'),
    (37,  'Canada'),
    (94,  'Indonesia'),
    (148, 'New Zealand'),
    (162, 'Philippines'),
    (166, 'Qatar'),
    (184, 'Singapore'),
    (189, 'South Africa'),
    (191, 'Sri Lanka'),
    (208, 'Turkey'),
    (214, 'UAE'),
    (215, 'United Kingdom'),
    (216, 'United States');


-- =====================================================================
-- PART 1: DATA QUALITY CHECKS
-- =====================================================================

-- 1.1 Total rows and duplicate IDs (should be equal -> no duplicates)
SELECT COUNT(*)                      AS total_rows,
       COUNT(DISTINCT restaurant_id) AS unique_ids
FROM market_analysis.restaurants;

-- 1.2 Missing values: empty cells (NULL) and zeros that actually mean "no data"
SELECT COUNT(*) FILTER (WHERE cuisines IS NULL)              AS missing_cuisines,
       COUNT(*) FILTER (WHERE city IS NULL)                  AS missing_city,
       COUNT(*) FILTER (WHERE aggregate_rating IS NULL)      AS missing_rating,
       COUNT(*) FILTER (WHERE aggregate_rating = 0)          AS zero_rating,
       COUNT(*) FILTER (WHERE average_cost_for_two IS NULL)  AS missing_cost,
       COUNT(*) FILTER (WHERE average_cost_for_two = 0)      AS zero_cost
FROM market_analysis.restaurants;

-- 1.3 What does a rating of 0 mean? All 0 ratings are labelled 'Not rated',
--     and the lowest real rating is 1.8 -> 0 means "no rating", not a bad rating.
--     These rows are excluded from all rating averages.
SELECT rating_text,
       COUNT(*)              AS number_of_restaurants,
       MIN(aggregate_rating) AS min_rating,
       MAX(aggregate_rating) AS max_rating
FROM market_analysis.restaurants
GROUP BY rating_text
ORDER BY min_rating;

-- 1.4 Impact of the "Not rated" rows on the average
SELECT ROUND(AVG(aggregate_rating), 2)                                  AS avg_all_rows,
       ROUND(AVG(aggregate_rating) FILTER (WHERE aggregate_rating > 0), 2) AS avg_rated_only
FROM market_analysis.restaurants;

-- 1.5 Columns with (almost) no variation carry no information
SELECT switch_to_order_menu, is_delivering_now, COUNT(*) AS number_of_restaurants
FROM market_analysis.restaurants
GROUP BY switch_to_order_menu, is_delivering_now;

-- 1.6 Country distribution and currencies.
--     Costs are in 12 different currencies, so average_cost_for_two
--     can only be compared WITHIN a country, never across countries.
SELECT c.country_name,
       r.currency,
       COUNT(*) AS number_of_restaurants,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_total
FROM market_analysis.restaurants r
JOIN market_analysis.countries c ON c.country_code = r.country_code
GROUP BY c.country_name, r.currency
ORDER BY number_of_restaurants DESC;

-- 1.7 Restaurant names repeat because of chains -> always count by restaurant_id
SELECT COUNT(*) - COUNT(DISTINCT restaurant_name) AS repeated_names
FROM market_analysis.restaurants;

-- 1.8 SAMPLING CHECK: the dataset does not cover all cities equally.
--     Delhi NCR has ~1,600 restaurants per city (full coverage, incl. unrated ones),
--     while every other city has only ~10-20 restaurants, almost all of them rated
--     and with a much higher average -> they look like a sample of top restaurants.
--     Conclusion: comparing ratings across cities/countries would be misleading,
--     so the "what drives a rating" analysis in PART 3 uses Delhi NCR only.
SELECT CASE
           WHEN city IN ('New Delhi', 'Gurgaon', 'Noida', 'Faridabad', 'Ghaziabad') THEN 'Delhi NCR'
           WHEN country_code = 1 THEN 'Rest of India'
           ELSE 'Outside India'
       END                                                           AS region,
       COUNT(*)                                                      AS number_of_restaurants,
       COUNT(DISTINCT city)                                          AS number_of_cities,
       ROUND(COUNT(*)::NUMERIC / COUNT(DISTINCT city), 1)            AS restaurants_per_city,
       ROUND(100.0 * AVG((rating_text = 'Not rated')::INT), 1)       AS pct_not_rated,
       ROUND(AVG(aggregate_rating) FILTER (WHERE aggregate_rating > 0), 2) AS average_rating
FROM market_analysis.restaurants
GROUP BY region
ORDER BY number_of_restaurants DESC;


-- =====================================================================
-- CLEAN VIEWS used for the analysis below
--   v_rated : only rated restaurants (rating_text <> 'Not rated') + country name
--   v_ncr   : v_rated limited to Delhi NCR (the only fully covered market)
-- =====================================================================

CREATE OR REPLACE VIEW market_analysis.v_rated AS
SELECT r.*, c.country_name
FROM market_analysis.restaurants r
JOIN market_analysis.countries c ON c.country_code = r.country_code
WHERE r.rating_text <> 'Not rated';

CREATE OR REPLACE VIEW market_analysis.v_ncr AS
SELECT *
FROM market_analysis.v_rated
WHERE city IN ('New Delhi', 'Gurgaon', 'Noida', 'Faridabad', 'Ghaziabad');


-- =====================================================================
-- PART 2: EXPLORATORY DATA ANALYSIS
-- =====================================================================

-- 2.1 Number of restaurants, cities and countries
SELECT COUNT(*)                     AS number_of_restaurants,
       COUNT(DISTINCT city)         AS number_of_cities,
       COUNT(DISTINCT country_code) AS number_of_countries
FROM market_analysis.restaurants;

-- 2.2 Top 10 cities by number of restaurants
SELECT city, COUNT(*) AS number_of_restaurants
FROM market_analysis.restaurants
GROUP BY city
ORDER BY number_of_restaurants DESC
LIMIT 10;

-- 2.3 Top 10 cuisines.
--     The cuisines column holds a comma-separated list ("North Indian, Chinese"),
--     so it is split into one row per cuisine before counting.
SELECT TRIM(cuisine) AS cuisine,
       COUNT(*)      AS number_of_restaurants
FROM market_analysis.restaurants,
     UNNEST(STRING_TO_ARRAY(cuisines, ',')) AS cuisine
GROUP BY TRIM(cuisine)
ORDER BY number_of_restaurants DESC
LIMIT 10;

-- 2.4 Average rating of rated restaurants
SELECT ROUND(AVG(aggregate_rating), 2) AS average_rating
FROM market_analysis.v_rated;

-- 2.5 Average cost for two by price range, per country (in local currency)
SELECT country_name,
       currency,
       price_range,
       ROUND(AVG(average_cost_for_two)) AS avg_cost_for_two
FROM market_analysis.v_rated
GROUP BY country_name, currency, price_range
ORDER BY country_name, price_range;


-- =====================================================================
-- PART 3: WHAT DRIVES A HIGH RATING?  (Delhi NCR, rated restaurants)
-- =====================================================================

-- 3.1 Rating and popularity by price range (1 = cheapest, 4 = most expensive)
SELECT price_range,
       COUNT(*)                        AS number_of_restaurants,
       ROUND(AVG(aggregate_rating), 2) AS average_rating,
       ROUND(AVG(votes))               AS average_votes
FROM market_analysis.v_ncr
GROUP BY price_range
ORDER BY price_range;

-- 3.2 Online delivery vs. rating, within each price range
--     (comparing inside the same price range so price does not distort the result)
SELECT price_range,
       has_online_delivery,
       COUNT(*)                        AS number_of_restaurants,
       ROUND(AVG(aggregate_rating), 2) AS average_rating
FROM market_analysis.v_ncr
GROUP BY price_range, has_online_delivery
ORDER BY price_range, has_online_delivery;

-- 3.3 Table booking vs. rating, within each price range
SELECT price_range,
       has_table_booking,
       COUNT(*)                        AS number_of_restaurants,
       ROUND(AVG(aggregate_rating), 2) AS average_rating
FROM market_analysis.v_ncr
GROUP BY price_range, has_table_booking
ORDER BY price_range, has_table_booking;

-- 3.4 Best- and worst-rated cuisines (at least 50 rated restaurants each)
WITH cuisine_stats AS (
    SELECT TRIM(cuisine)                   AS cuisine,
           COUNT(*)                        AS number_of_restaurants,
           ROUND(AVG(aggregate_rating), 2) AS average_rating
    FROM market_analysis.v_ncr,
         UNNEST(STRING_TO_ARRAY(cuisines, ',')) AS cuisine
    GROUP BY TRIM(cuisine)
    HAVING COUNT(*) >= 50
),
ranked AS (
    SELECT *,
           RANK() OVER (ORDER BY average_rating DESC) AS best_rank,
           RANK() OVER (ORDER BY average_rating ASC)  AS worst_rank
    FROM cuisine_stats
)
SELECT CASE WHEN best_rank <= 5 THEN 'Top 5' ELSE 'Bottom 5' END AS grp,
       cuisine, number_of_restaurants, average_rating
FROM ranked
WHERE best_rank <= 5 OR worst_rank <= 5
ORDER BY average_rating DESC;

-- 3.5 Correlation of rating with votes and price range
--     (LN(votes) is used because votes are heavily right-skewed)
SELECT ROUND(CORR(votes, aggregate_rating)::NUMERIC, 2)       AS corr_votes,
       ROUND(CORR(LN(votes), aggregate_rating)::NUMERIC, 2)   AS corr_log_votes,
       ROUND(CORR(price_range, aggregate_rating)::NUMERIC, 2) AS corr_price_range
FROM market_analysis.v_ncr;


-- =====================================================================
-- PART 4: RANKINGS AND SEGMENTS
-- =====================================================================

-- 4.1 Top 10 highest-rated restaurants with more than 500 votes
--     (votes used as a tie-breaker, since many share a 4.9 rating)
SELECT restaurant_name, city, country_name, aggregate_rating, votes
FROM market_analysis.v_rated
WHERE votes > 500
ORDER BY aggregate_rating DESC, votes DESC
LIMIT 10;

-- 4.2 Best restaurant in each Delhi NCR city (window function)
WITH ranked AS (
    SELECT city,
           restaurant_name,
           aggregate_rating,
           votes,
           RANK() OVER (PARTITION BY city
                        ORDER BY aggregate_rating DESC, votes DESC) AS rank_in_city
    FROM market_analysis.v_ncr
)
SELECT city, restaurant_name, aggregate_rating, votes
FROM ranked
WHERE rank_in_city = 1
ORDER BY aggregate_rating DESC;

-- 4.3 Popularity segments based on votes, with share of restaurants
--     and the average rating in each segment (Delhi NCR)
WITH segments AS (
    SELECT restaurant_id,
           aggregate_rating,
           CASE
               WHEN votes < 100   THEN '1. Low Popularity (<100)'
               WHEN votes <= 1000 THEN '2. Moderately Popular (100-1000)'
               ELSE                    '3. Highly Popular (>1000)'
           END AS popularity
    FROM market_analysis.v_ncr
)
SELECT popularity,
       COUNT(*)                                            AS number_of_restaurants,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_of_restaurants,
       ROUND(AVG(aggregate_rating), 2)                     AS average_rating
FROM segments
GROUP BY popularity
ORDER BY popularity;

-- 4.4 Restaurants rated above the overall average (CTE):
--     how many there are and what they look like compared to the rest (Delhi NCR)
WITH average_rating AS (
    SELECT AVG(aggregate_rating) AS avg_rating
    FROM market_analysis.v_ncr
)
SELECT CASE WHEN v.aggregate_rating > a.avg_rating
            THEN 'Above average' ELSE 'At or below average' END           AS grp,
       COUNT(*)                                                           AS number_of_restaurants,
       ROUND(AVG(v.price_range), 2)                                       AS avg_price_range,
       ROUND(100.0 * AVG((v.has_table_booking = 'Yes')::INT), 1)          AS pct_table_booking,
       ROUND(100.0 * AVG((v.has_online_delivery = 'Yes')::INT), 1)        AS pct_online_delivery,
       ROUND(AVG(v.votes))                                                AS average_votes
FROM market_analysis.v_ncr v
CROSS JOIN average_rating a
GROUP BY grp
ORDER BY grp;

-- 4.5 Largest chains: number of outlets and how consistent their rating is
SELECT restaurant_name,
       COUNT(*)                           AS number_of_outlets,
       ROUND(AVG(aggregate_rating), 2)    AS average_rating,
       ROUND(STDDEV(aggregate_rating), 2) AS rating_std_dev
FROM market_analysis.v_rated
GROUP BY restaurant_name
HAVING COUNT(*) >= 10
ORDER BY number_of_outlets DESC
LIMIT 10;
