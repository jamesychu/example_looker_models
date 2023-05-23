WITH n AS
(
SELECT 
  item_fulfillment_id
  , customer_id
  , CASE WHEN sor_netsuite_customer_recor_id IS NULL OR sor_netsuite_customer_recor_id = '' THEN customer_id ELSE sor_netsuite_customer_recor_id END AS end_customer_id
  , item_id
  , count(DISTINCT install_base_name) AS numerator
FROM netsuite.install_base GROUP BY 1,2,3,4)
, d AS
(
SELECT 
  item_fulfillment_id
  , item_id
  , count(DISTINCT install_base_name) AS denominator
FROM netsuite.install_base GROUP BY 1,2)

, percentages AS
(
SELECT
	n.item_fulfillment_id
	, end_customer_id
	, n.item_id
	, numerator::float
	, denominator::float
	, numerator::float/denominator::float AS allocation
FROM
	n
INNER JOIN d on n.item_fulfillment_id = d.item_fulfillment_id and n.item_id = d.item_id
GROUP BY 1,2,3,4,5,6
)
, population AS(
SELECT item_fulfillment_id FROM netsuite.install_base WHERE sor_netsuite_customer_recor_id IS NOT NULL GROUP BY 1)
, base AS(
SELECT
    if.transaction_line_id
    , if.transaction_id
    , if.fulfillment_date
    , EXTRACT(quarter FROM if.fulfillment_date) || 'Q' || RIGHT(EXTRACT(year FROM if.fulfillment_date),2) AS fulfillment_quarter
    , so.sales_order_tran_date
    , if.revenue_channel_id
    , if.customer_id
    , if.revenue_channel_name
    , CASE
        WHEN if.revenue_channel_name = 'E-commerce' THEN 'REDACTED'
        WHEN if.customer_id = 4560 OR if.customer_id = 1351033 THEN 'REDACTED'
        WHEN if.customer_id = 129881 OR if.customer_id = 5486306 THEN 'REDACTED'
        WHEN if.customer_id IN (598202,8211998) THEN 'REDACTED'
        WHEN if.revenue_channel_name IN ('Reseller','Partnerships','Distributor') THEN 'Other Retail'
        WHEN if.revenue_channel_name IN ('Pro','Builder') THEN 'Pro'
        WHEN if.revenue_channel_name = 'ISP' THEN 'ISP'
        ELSE 'Other' END AS sales_channel_category
    , if.fulfillment_number
    , if.fulfillment_status
    , so.sales_order_number
    , so.sales_order_status
    , so.title_transfer
    , if.item_id
    , if.sku
    , if.original_sku
    , if.number_items_in_pack
    , if.quantity AS skus_fulfilled
    , if.number_items_in_pack * if.quantity AS units_fulfilled
    , so.avg_per_sku_rate
    , if.quantity * so.avg_per_sku_rate AS total_gross_amount
    , if.if_ship_country


        -- subquery for item fulfillment qty


FROM (
  SELECT
    ntl.unique_key AS transaction_line_id
    , nt.transaction_id
    , nt.trandate::date AS fulfillment_date
    , nt.revenue_channel_id
    , nrc.revenue_channel_name
    , nt.entity_id AS customer_id
    , nt.transaction_number AS fulfillment_number
    , nt.created_from_id
    , nt.status AS fulfillment_status
    , ni.item_id
    , ni.full_name AS sku
    , nrr.revenue_region_name AS  if_revenue_region
    , nta.ship_country AS if_ship_country
    , CASE
        WHEN len(ni.full_name) = 7
          AND substring(ni.full_name,6,1) = '1'
          AND upper(left(ni.full_name,1)) SIMILAR TO '[A-Z]' THEN substring(ni.full_name,1,5) || '0' || substring(ni.full_name,7,1)
        ELSE ni.full_name END AS original_sku
    , ni.number_items_in_pack
    , -(sum(ntl.item_count)) AS quantity
  FROM netsuite.transactions nt
  LEFT JOIN netsuite.transaction_lines ntl ON nt.transaction_id = ntl.transaction_id
  LEFT JOIN netsuite.customers nc ON  nt.entity_id = nc.customer_id
  LEFT JOIN netsuite.items ni ON ntl.item_id = ni.item_id
  LEFT JOIN netsuite.revenue_channel nrc ON nt.revenue_channel_id = nrc.revenue_channel_id
  LEFT JOIN netsuite.revenue_region nrr ON nrr.revenue_region_id = nt.revenue_region_id
  LEFT JOIN netsuite.transaction_address nta ON nta.transaction_id = nt.transaction_id
  WHERE nt.status IN ('Shipped')
    AND ni.full_name NOT IN ('750-00003','750-00004','810-00001-Q','810-00101-B','810-00101-RTV','810-00201-B','840-00002','840-00004','855-00048','855-00049') -- excludes quarantine/failed units, shipping labels, packaging and power source assembly items
    AND ntl.account_id = 123 -- Account is 1320 Inventory : Finished Goods
    AND nt.revenue_channel_id NOT IN (1,4,6,7,13) -- excludes Beta Tester, Pre-Order, RMA, Sales and Marketing, Legacy
    AND nt.transaction_type = 'Item Fulfillment'
  GROUP BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15) AS if -- item fulfillment sub-query, transactions used as the basis for bookings

        -- subquery with average rates


LEFT JOIN (
  SELECT
    nt.transaction_id
    , nt.trandate::date AS sales_order_tran_date
    , nt.tranid AS sales_order_number
    , nt.status AS sales_order_status
    , nrr.revenue_region_name AS so_revenue_region
    , nta.ship_country AS so_ship_country
    , CASE
        WHEN ne.title_transfer_id = 1 THEN 'On Shipment'
        WHEN ne.title_transfer_id =2 THEN 'On Delivery'
        ELSE 'New Title Transfer Type' END AS title_transfer
    , ni.full_name AS sku
    , (sum(ntl.gross_amount))/(sum(ntl.item_count)) AS avg_per_sku_rate
  FROM netsuite.transactions nt
  LEFT JOIN netsuite.transaction_lines ntl ON nt.transaction_id = ntl.transaction_id
  LEFT JOIN netsuite.items ni ON ntl.item_id = ni.item_id
  LEFT JOIN netsuite.entity ne ON nt.entity_id = ne.entity_id
  LEFT JOIN netsuite.revenue_region nrr ON nrr.revenue_region_id = nt.revenue_region_id
  LEFT JOIN netsuite.transaction_address nta ON nta.transaction_id = nt.transaction_id
  WHERE nt.transaction_type = 'Sales Order'
  AND ntl.item_count != 0
  GROUP BY 1,2,3,4,5,6,7,8) AS so -- sales order sub-query, transactions used to determine the average rate per sku on related item fulfillments
    ON if.created_from_id = so.transaction_id AND if.sku = so.sku)


SELECT *, '' AS end_customer_id FROM base where base.transaction_id NOT IN (SELECT * from population) 

UNION
 
SELECT
    base.transaction_line_id
    , base.transaction_id
    , base.fulfillment_date
    , base.fulfillment_quarter
    , base.sales_order_tran_date
    , base.revenue_channel_id
    , base.customer_id
    , base.revenue_channel_name
    , CASE
        WHEN end_customer_id IN (129881,5486306) THEN 'REDACTED'
        WHEN end_customer_id IN (4560,135103,8038322,7225817) THEN 'REDACTED'
        WHEN end_customer_id IN (598202,8211998) THEN 'REDACTED'
        ELSE base.sales_channel_category END AS sales_channel_category
    , base.fulfillment_number
    , base.fulfillment_status
    , base.sales_order_number
    , base.sales_order_status
    , base.title_transfer
    , base.item_id
    , base.sku
    , base.original_sku
    , base.number_items_in_pack
    , base.skus_fulfilled * percentages.allocation::float AS skus_fulfilled
    , base.units_fulfilled * percentages.allocation::float AS units_fulfilled
    , base.avg_per_sku_rate
    , base.total_gross_amount * percentages.allocation::float AS total_gross_amount
    , base.if_ship_country
    , end_customer_id

FROM base
INNER JOIN percentages ON base.transaction_id = percentages.item_fulfillment_id AND base.item_id = percentages.item_id
INNER JOIN netsuite.customers c ON c.customer_id = end_customer_id
WHERE base.transaction_id IN (SELECT * FROM population)
GROUP  BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24


