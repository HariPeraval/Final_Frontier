---Table Alter for SKU and DEPT Store and store_group--
alter table zms_ifi_pick_sku_override add (store_group varchar2(50),store number(10));
alter table zms_ifi_pick_dept_override add (store_group varchar2(50),store number(10));
