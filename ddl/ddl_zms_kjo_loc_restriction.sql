drop table zms.zms_kjo_loc_restriction cascade constraints;
create table zms.zms_kjo_loc_restriction
(
  Location            number(10),
  Source_Destination  varchar2(25 byte),
  ims_tran_type       VARCHAR2(4 BYTE), 
  tran_category       VARCHAR2(10 BYTE),
  active_flag         VARCHAR2(1 BYTE),
  Create_date         date
) ;
create index zms.zms_kjo_loc_rest_i1 on zms.zms_kjo_loc_restriction(Location, Source_Destination, ims_tran_type) ;
create or replace public synonym zms_kjo_loc_restriction for zms.zms_kjo_loc_restriction;
grant select on zms.zms_kjo_loc_restriction to esb_default_ro_role;
grant select on zms.zms_kjo_loc_restriction to infa_ro;
grant delete, insert, select, update on zms.zms_kjo_loc_restriction to infa_rw;
grant delete, insert, select, update on zms.zms_kjo_loc_restriction to rms_role;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_loc_restriction to rms_user;
grant alter, delete, index, insert, references, select, update, on commit refresh, query rewrite, debug, flashback on zms.zms_kjo_loc_restriction to zmsbatch;
