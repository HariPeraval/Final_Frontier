
---New Tables for SKU and DEPT Store and store_group--
drop table zms.zms_zpf_sku_store_group_ovrd; 
create table zms.zms_zpf_sku_store_group_ovrd
( wh           number(10),
  sku          varchar2(10 byte),
  store        number(10),
  store_group  varchar2(50),
  data_source  varchar2(10 byte),
  indicator    varchar2(1 byte)
) ; 
create index zms.zms_zpf_sku_store_group_i1 on zms.zms_zpf_sku_store_group_ovrd(wh, sku,store) ; 
create index zms.zms_zpf_sku_store_grp_ov_i1 on zms.zms_zpf_sku_store_group_ovrd(STORE_GROUP) ; 
create or replace public synonym zms_zpf_sku_store_group_ovrd for zms.zms_zpf_sku_store_group_ovrd;  
grant select on zms.zms_zpf_sku_store_group_ovrd to esb_default_ro_role;  
grant select on zms.zms_zpf_sku_store_group_ovrd to infa_ro; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_group_ovrd to infa_rw; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_group_ovrd to rms_role; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_group_ovrd to rms_role_temp; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_store_group_ovrd to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_store_group_ovrd to zmsbatch;

drop table zms.zms_temp_dept_stor_group_ovrd; 
create table zms.zms_temp_dept_stor_group_ovrd
( wh           number(10),
  division     number(3),
  dept         number(5),
  class        number(5),
  subclass     number(5),
  store        number(10),
  store_group  varchar2(50),
  data_source  varchar2(10 byte),
  indicator    varchar2(3 byte)
); 

drop table zms.zms_zpf_sku_replenishment; 
create table zms.zms_zpf_sku_replenishment
( division           number(5)                  not null,
  group_name         varchar2(120 byte)         not null,
  group_id           varchar2(120 byte),
  store              number(5)                  not null,
  group_type         varchar2(3 byte)           not null,
  creation_date      date                       not null,
  created_by         varchar2(90 byte)          not null,
  last_updated_date  date                       not null,
  last_updated_by    varchar2(90 byte)          not null,
  priority_code      number(10)
) ;  
create or replace public synonym zms_zpf_sku_replenishment for zms.zms_zpf_sku_replenishment; 

drop table zms.zms_zpf_sku_str_replenishment;
create table zms.zms_zpf_sku_str_replenishment
( division           number(5)                  not null,
  group_name         varchar2(120 byte)         not null,
  group_id           varchar2(120 byte),
  store              number(5)                  not null,
  group_type         varchar2(3 byte)           not null,
  creation_date      date                       not null,
  created_by         varchar2(90 byte)          not null,
  last_updated_date  date                       not null,
  last_updated_by    varchar2(90 byte)          not null,
  priority_code      number(10)
);

drop table zms.zms_zpf_sku_pick_day_stores ; 
create table zms.zms_zpf_sku_pick_day_stores
( wh           number(10),
  store        number(10),
  div          number(3),
  store_group  varchar2(50),
  data_source  varchar2(10 byte),
  dist_type    varchar2(6 byte)
) ; 
create index zms.zms_zpf_sku_pick_day_st_i1 on zms.zms_zpf_sku_pick_day_stores(wh, store) ; 
create index zms.zms_zpf_sku_PICK_DAY_STR_i1 on zms.zms_zpf_sku_PICK_DAY_STORES(STORE_GROUP) ; 
create or replace public synonym zms_zpf_sku_pick_day_stores for zms.zms_zpf_sku_pick_day_stores; 
grant select on zms.zms_zpf_sku_pick_day_stores to esb_default_ro_role; 
grant select on zms.zms_zpf_sku_pick_day_stores to infa_ro; 
grant delete, insert, select, update on zms.zms_zpf_sku_pick_day_stores to infa_rw;  
grant delete, insert, select, update on zms.zms_zpf_sku_pick_day_stores to rms_role;
grant delete, insert, select, update on zms.zms_zpf_sku_pick_day_stores to rms_role_temp;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_pick_day_stores to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_pick_day_stores to zmsbatch;

---New Tables for KJF Brand--
drop table zms.zms_kjo_wh_control cascade constraints; 
create table zms.zms_kjo_wh_control
( div          number,
  orig_wh      number(10),
  process_no   number,
  pick_wh      number(10),
  prev_wh      number(10),
  active_flag  varchar2(1 byte)
) ;  
create or replace public synonym zms_kjo_wh_control for zms.zms_kjo_wh_control; 
grant select on zms.zms_kjo_wh_control to esb_default_ro_role; 
grant select on zms.zms_kjo_wh_control to infa_ro; 
grant delete, insert, select, update on zms.zms_kjo_wh_control to infa_rw; 
grant delete, insert, select, update on zms.zms_kjo_wh_control to rms_role; 
grant delete, insert, select, update on zms.zms_kjo_wh_control to rms_role_temp; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_wh_control to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_wh_control to zmsbatch;
 
drop table zms.zms_kjo_div_extract cascade constraints;
create table zms.zms_kjo_div_extract
(
  store             number(10),
  sku               varchar2(10 byte),
  req               number(10),
  po_line_nbr       number(10),
  po_type           varchar2(2 byte),
  division          number(3),
  ord_qty           number(10),
  store_priority    number(5),
  in_str_date       date,
  priority          number(1),
  repl_sku_group    varchar2(10 byte),
  watch_priority    number(1),
  dist_type         varchar2(2 byte),
  wh                number(10),
  request_sku       varchar2(10 byte),
  stock_on_hand     number(12,4),
  stock_avail       number(12,4),
  move_order_id     number,
  alloc_id          number,
  distro_date       date,
  cust_name         varchar2(200 byte),
  orig_wh           number(10),
  orig_req          number(10),
  orig_po_type      varchar2(2 byte),
  orig_ord_qty      number(10),
  pick_process_nbr  number(10)
) ;
create index zms.zms_kjo_div_extract_i1 on zms.zms_kjo_div_extract(sku, store) ;
create index zms.zms_kjo_div_extract_i2 on zms.zms_kjo_div_extract(store, sku, ord_qty, req) ;
create or replace public synonym zms_kjo_div_extract for zms.zms_kjo_div_extract;
grant select on zms.zms_kjo_div_extract to esb_default_ro_role;
grant select on zms.zms_kjo_div_extract to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_div_extract to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_div_extract to rms_role;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_div_extract to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_div_extract to zmsbatch;
 

drop table zms.zms_kjo_win_wh cascade constraints;
create table zms.zms_kjo_win_wh
(
  sku          varchar2(10 byte)                not null,
  wh           number(5)                        not null,
  stock_avail  number(6)
) ;  
create index zms.zms_kjo_win_wh_i1 on zms.zms_kjo_win_wh(wh, sku) ; 
create or replace public synonym zms_kjo_win_wh for zms.zms_kjo_win_wh;  
grant select on zms.zms_kjo_win_wh to esb_default_ro_role; 
grant select on zms.zms_kjo_win_wh to infa_ro; 
grant delete, insert, select, update on zms.zms_kjo_win_wh to infa_rw; 
grant delete, insert, select, update on zms.zms_kjo_win_wh to rms_role; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh to zmsbatch;


drop table zms.zms_kjo_win_wh1 cascade constraints;
create table zms.zms_kjo_win_wh1
(
  sku          varchar2(10 byte)                not null,
  wh           number(5)                        not null,
  stock_avail  number(6)
) ; 
create index zms.zms_kjo_win_wh1_i1 on zms.zms_kjo_win_wh1(wh, sku) ; 
create or replace public synonym zms_kjo_win_wh1 for zms.zms_kjo_win_wh1; 
grant select on zms.zms_kjo_win_wh1 to esb_default_ro_role; 
grant select on zms.zms_kjo_win_wh1 to infa_ro; 
grant delete, insert, select, update on zms.zms_kjo_win_wh1 to infa_rw; 
grant delete, insert, select, update on zms.zms_kjo_win_wh1 to rms_role; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh1 to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh1 to zmsbatch;

drop table zms.zms_kjo_store_pick_priority cascade constraints; 
create table zms.zms_kjo_store_pick_priority
(
  division           number(5)                  not null,
  group_name         varchar2(120 byte)         not null,
  group_id           varchar2(120 byte),
  store              number(5)                  not null,
  group_type         varchar2(3 byte)           not null,
  creation_date      date                       not null,
  created_by         varchar2(90 byte)          not null,
  last_updated_date  date                       not null,
  last_updated_by    varchar2(90 byte)          not null,
  priority_code      number(10)
) ; 

create or replace public synonym zms_kjo_store_pick_priority for zms.zms_kjo_store_pick_priority; 
grant select on zms.zms_kjo_store_pick_priority to esb_default_ro_role; 
grant select on zms.zms_kjo_store_pick_priority to infa_ro; 
grant delete, insert, select, update on zms.zms_kjo_store_pick_priority to infa_rw; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_store_pick_priority to zmsbatch;

drop table zms.zms_kjo_sku_store_override; 
create table zms.zms_kjo_sku_store_override
( wh           number(10),
  sku          varchar2(10 byte),
  store        number(10), 
  div          number(3),
  data_source  varchar2(10 byte),
  indicator    varchar2(1 byte)
) ; 
create index zms.zms_kjo_sku_store_override_i1 on zms.zms_kjo_sku_store_override(wh, sku,store) ; 
create or replace public synonym zms_kjo_sku_store_override for zms.zms_kjo_sku_store_override;  
grant select on zms.zms_kjo_sku_store_override to esb_default_ro_role;  
grant select on zms.zms_kjo_sku_store_override to infa_ro; 
grant delete, insert, select, update on zms.zms_kjo_sku_store_override to infa_rw; 
grant delete, insert, select, update on zms.zms_kjo_sku_store_override to rms_role; 
grant delete, insert, select, update on zms.zms_kjo_sku_store_override to rms_role_temp; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_sku_store_override to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_sku_store_override to zmsbatch; 
/


drop table zms.zms_kjo_win_wh_bk cascade constraints;
create table zms.zms_kjo_win_wh_bk
(
  sku           varchar2(10 byte),
  wh            number(5),
  stock_avail   number(6),
  process_type  varchar2(20 byte),
  process_date  date
) ;

create or replace public synonym zms_kjo_win_wh_bk for zms.zms_kjo_win_wh_bk;
grant select on zms.zms_kjo_win_wh_bk to bouser_ro;
grant select on zms.zms_kjo_win_wh_bk to esb_default_ro_role;
grant select on zms.zms_kjo_win_wh_bk to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_win_wh_bk to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_win_wh_bk to rms_role;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh_bk to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_win_wh_bk to zmsbatch;

drop table zms.zms_kjo_main_sub cascade constraints;
create table zms.zms_kjo_main_sub
(
  item                varchar2(25 byte),
  sub_item            varchar2(25 byte),
  item_pick_priority  number(3)
) ;
create index zms.zms_kjo_main_sub_i1 on zms.zms_kjo_main_sub(item, sub_item, item_pick_priority) ;
create or replace public synonym zms_kjo_main_sub for zms.zms_kjo_main_sub;
grant select on zms.zms_kjo_main_sub to esb_default_ro_role;
grant select on zms.zms_kjo_main_sub to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_main_sub to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_main_sub to rms_role;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_main_sub to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_main_sub to zmsbatch;

drop table zms.zms_kjo_pick_day_stores cascade constraints;
create table zms.zms_kjo_pick_day_stores
(
  wh           number(10),
  store        number(10),
  div          number(3),
  data_source  varchar2(10 byte),
  dist_type    varchar2(6 byte)
) ; 

create index zms.zms_kjo_pick_day_stores_i1 on zms.zms_kjo_pick_day_stores(wh, store) ;
create or replace public synonym zms_kjo_pick_day_stores for zms.zms_kjo_pick_day_stores;
grant select on zms.zms_kjo_pick_day_stores to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_pick_day_stores to infa_rw;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_pick_day_stores to zmsbatch;

drop table zms.zms_zpf_fm_stores cascade constraints;
create table zms.zms_zpf_fm_stores
(
  store        number(10), 
  dist_type    varchar2(6 byte)
) ; 

create index zms.zms_zpf_fm_stores_i1 on zms.zms_zpf_fm_stores(store) ;
create or replace public synonym zms_zpf_fm_stores for zms.zms_zpf_fm_stores;
grant select on zms.zms_zpf_fm_stores to infa_ro;
grant delete, insert, select, update on zms.zms_zpf_fm_stores to infa_rw;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_fm_stores to zmsbatch;
 

drop table zms.zms_kjo_div_extract_bk cascade constraints;
create table zms.zms_kjo_div_extract_bk
(
  store             number(10),
  sku               varchar2(10 byte),
  req               number(10),
  po_line_nbr       number(10),
  po_type           varchar2(2 byte),
  division          number(3),
  ord_qty           number(10),
  store_priority    number(10),
  in_str_date       date,
  priority          number(1),
  repl_sku_group    varchar2(10 byte),
  watch_priority    number(1),
  dist_type         varchar2(2 byte),
  wh                number(10),
  request_sku       varchar2(10 byte),
  stock_on_hand     number(12,4),
  stock_avail       number(12,4),
  move_order_id     number,
  alloc_id          number,
  distro_date       date,
  process_type      varchar2(15 byte),
  process_date      date,
  orig_wh           number(10),
  orig_req          number(10),
  orig_po_type      varchar2(2 byte),
  orig_ord_qty      number(10),
  cust_name         varchar2(200 byte),
  pick_process_nbr  number(10)
) ;
create or replace public synonym zms_kjo_div_extract_bk for zms.zms_kjo_div_extract_bk;
grant select on zms.zms_kjo_div_extract_bk to esb_default_ro_role;
grant select on zms.zms_kjo_div_extract_bk to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_div_extract_bk to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_div_extract_bk to rms_role;
grant delete, insert, select, update on zms.zms_kjo_div_extract_bk to rms_role_temp;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_div_extract_bk to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_div_extract_bk to zmsbatch;

alter table zms.zms_kjo_nopick_report drop primary key cascade;
drop table zms.zms_kjo_nopick_report cascade constraints;
create table zms.zms_kjo_nopick_report
(
  sku             varchar2(10 byte)             not null,
  repl_sku_group  varchar2(10 byte)             not null,
  req             number(10)                    not null,
  store           number(5)                     not null,
  division        number(4),
  dept            number(4),
  dist_type       varchar2(2 byte),
  unit_cost       number(8,2),
  unit_retail     number(8,2),
  req_qty         number(4),
  pick_qty        number(4),
  in_str_date     date,
  reason_code     varchar2(10 byte)
);
create unique index zms.pk_zms_kjo_nopick_report on zms.zms_kjo_nopick_report(sku, repl_sku_group, req, store);
create index zms.zms_kjo_nopick_report_idx1 on zms.zms_kjo_nopick_report(sku, store, req);
create or replace public synonym zms_kjo_nopick_report for zms.zms_kjo_nopick_report;
alter table zms.zms_kjo_nopick_report add (constraint pk_zms_kjo_nopick_report primary key(sku, repl_sku_group, req, store) using index zms.pk_zms_kjo_nopick_report enable validate);
grant select on zms.zms_kjo_nopick_report to esb_default_ro_role;
grant select on zms.zms_kjo_nopick_report to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_nopick_report to infa_rw;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_nopick_report to zmsbatch;

drop table zms.zms_kjo_new_tsf_no cascade constraints;
create table zms.zms_kjo_new_tsf_no
(
  wh         number(10),
  store      number(10),
  req        number(10),
  cust_name  varchar2(200 byte)
) ;
create index zms.zms_kjo_new_tsf_no_i1 on zms.zms_kjo_new_tsf_no(wh, store, req) ;
create or replace public synonym zms_kjo_new_tsf_no for zms.zms_kjo_new_tsf_no;
grant select on zms.zms_kjo_new_tsf_no to esb_default_ro_role;
grant select on zms.zms_kjo_new_tsf_no to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_new_tsf_no to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_new_tsf_no to rms_role;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_new_tsf_no to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_new_tsf_no to zmsbatch;
 
 
---New Tables for SKU and DEPT Store and store_group--
drop table zms.zms_zpf_sku_store_ovrd; 
create table zms.zms_zpf_sku_store_ovrd
( wh           number(10),
  sku          varchar2(10 byte),
  store        number(10), 
  data_source  varchar2(10 byte),
  indicator    varchar2(1 byte)
) ; 
create index zms.zms_zpf_sku_store_ovrd_i1 on zms.zms_zpf_sku_store_ovrd(wh,sku,store) ;  
create or replace public synonym zms_zpf_sku_store_ovrd for zms.zms_zpf_sku_store_ovrd;  
grant select on zms.zms_zpf_sku_store_ovrd to esb_default_ro_role;  
grant select on zms.zms_zpf_sku_store_ovrd to infa_ro; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_ovrd to infa_rw; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_ovrd to rms_role; 
grant delete, insert, select, update on zms.zms_zpf_sku_store_ovrd to rms_role_temp; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_store_ovrd to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_store_ovrd to zmsbatch;


---New Tables for SKU and DEPT Store and store_group--
drop table zms.zms_zpf_sku_group_ovrd; 
create table zms.zms_zpf_sku_group_ovrd
( wh           number(10),
  sku          varchar2(10 byte), 
  store_group  varchar2(50),
  data_source  varchar2(10 byte),
  indicator    varchar2(1 byte)
) ; 
create index zms.zms_zpf_sku_group_ovrd_i1 on zms.zms_zpf_sku_group_ovrd(wh,sku,store_group) ;  
create or replace public synonym zms_zpf_sku_group_ovrd for zms.zms_zpf_sku_group_ovrd;  
grant select on zms.zms_zpf_sku_group_ovrd to esb_default_ro_role;  
grant select on zms.zms_zpf_sku_group_ovrd to infa_ro; 
grant delete, insert, select, update on zms.zms_zpf_sku_group_ovrd to infa_rw; 
grant delete, insert, select, update on zms.zms_zpf_sku_group_ovrd to rms_role; 
grant delete, insert, select, update on zms.zms_zpf_sku_group_ovrd to rms_role_temp; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_group_ovrd to rms_user; 
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_zpf_sku_group_ovrd to zmsbatch;
