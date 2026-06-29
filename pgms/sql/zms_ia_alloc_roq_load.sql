VARIABLE ret_code NUMBER;

SET doc off
SET feedback off
SET SERVEROUTPUT ON SIZE 1000000
WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR EXIT FAILURE;

/********************************************************************/
/*  FILENAME:     zms_ia_alloc_roq_load01.sql                       */
/*                                                                  */
/*  DESCRIPTION:  This process loads IA Allocations into            */
/*                Allocation tables                                 */
/*                                                                  */
/*  PARAMETERS:                                                     */
/*                                                                  */
/*  RESTART LOGIC:  Program is fully restartable.                   */
/*                                                                  */
/*  CHANGE HISTORY:                                                 */
/*      12/16/22  mschmidt  Created                                 */
/*                                                                  */
/********************************************************************/ 
-- 05/26/2026  Hari   -- Code change RMS Allocation load process from IA for KJO data
---------------------------------------------------------------------------------
-- GLOBAL VARIABLE DECLARATIONS
---------------------------------------------------------------------------------

DECLARE

  INIT_LOG_FAIL       EXCEPTION;
  CLOSE_LOG_FAIL      EXCEPTION;
  CURSOR_FAIL         EXCEPTION;
  FAILED_PROC         EXCEPTION;
  NO_DATA_TO_PROCESS  EXCEPTION;

  g_batch_date        DATE;
  g_debug_lvl         NUMBER := 1;
  g_return_code       NUMBER := 0;
  g_err_msg           VARCHAR2(500) := NULL;

  v_process_date      DATE := SYSDATE;
  v_alloc_cnt         NUMBER;
  v_table_name        VARCHAR2(50);
  v_sql_number        VARCHAR2(4);
  v_process_qty       NUMBER;
  v_sql               VARCHAR2(100);
  v_vdate             DATE;
  c_program           CONSTANT VARCHAR2(30) := 'zms_ia_alloc_roq_load';

---------------------------------------------------------------------------------
-- GLOBAL CURSOR DECLARATIONS
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- GLOBAL STRUCTURES
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- PROCEDURES/FUNCTIONS
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
-- Initialize process status
---------------------------------------------------------------------------------
PROCEDURE create_allocations(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  NO_DATA_TO_PROCESS_1  EXCEPTION;

  l_procname VARCHAR2(30) := 'create_allocations';

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

--
-- Create Allocations
--

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'zms_ifi_ia_alloc_roq';
    v_sql_number := '010';

    INSERT INTO zms_ifi_ia_alloc_roq
       (div, from_loc, to_loc, item, roq_qty, release_date,
        ia_allocation_id, vdate, process_status, error_msg, orig_qty, inner_pack_size, orig_from_loc)
    SELECT DISTINCT store_div, from_loc, to_loc, item, roq_qty, release_date,
           ia_allocation_id, vdate, DECODE(error_msg,NULL,'N','E') process_status, 
           error_msg, orig_qty, inner_pack_size, from_loc orig_from_loc
      FROM
       (SELECT DISTINCT zal2.store_div,
               CASE WHEN zal1.loc IS NOT NULL THEN zal1.loc
                    WHEN ia.from_loc LIKE 'A%' THEN TO_NUMBER(LPAD(REGEXP_REPLACE(ia.from_loc, '[^[:digit:]]', '' ),4,'0'))
                    ELSE TO_NUMBER(REGEXP_REPLACE(ia.from_loc, '[^[:digit:]]', '' )) END from_loc,
               CASE WHEN ia.to_loc LIKE 'A%' THEN TO_NUMBER(1||LPAD(REGEXP_REPLACE(ia.to_loc, '[^[:digit:]]', '' ),4,'0'))
                    ELSE TO_NUMBER(REGEXP_REPLACE(ia.to_loc, '[^[:digit:]]', '' )) END to_loc,
               ia.item, 
               DECODE(ia.roq_qty + (isc.inner_pack_size-MOD(ia.roq_qty,isc.inner_pack_size)-isc.inner_pack_size),
                      0,isc.inner_pack_size,
                      ia.roq_qty + (isc.inner_pack_size-MOD(ia.roq_qty,isc.inner_pack_size)-isc.inner_pack_size)) roq_qty,
               to_date(ia.release_date,'MMDDYYYY') release_date, ia.ia_allocation_id, get_vdate vdate,
               SUBSTR(
                     CASE WHEN im.item IS NULL THEN ' SKU Not Found "'||ia.item||'"'||' - ' ELSE NULL END
                  || CASE WHEN ia.roq_qty IS NULL THEN ' Alloc Qty is NULL - ' ELSE NULL END
                  || CASE WHEN REGEXP_LIKE(ia.roq_qty, '[[:alpha:]]') THEN ' Alloc Qty Not a Number "'||ia.roq_qty||'"'||' - ' ELSE NULL END
                  || CASE WHEN ia.roq_qty <> ROUND(ia.roq_qty,0) THEN 'Alloc Qty is a Decimal Value - ' ELSE NULL END
                  || CASE WHEN ia.from_loc IS NULL THEN 'IA From Loc is NULL - ' ELSE NULL END
                  || CASE WHEN ia.to_loc IS NULL THEN 'IA To Loc is NULL - ' ELSE NULL END
                  || CASE WHEN zal1.loc_four_digit IS NULL THEN 'From Loc Not Found' ELSE NULL END
                  || CASE WHEN zal2.loc_four_digit IS NULL THEN 'To Loc Not Found - ' ELSE NULL END
                  || CASE WHEN roq.ia_allocation_id IS NOT NULL THEN 'Duplicate IA Alloc' ELSE NULL END
                  || CASE WHEN iap.active_ind IS NULL THEN 'SKU Dept/Class/Subclass is not eligible' ELSE NULL END
                     ,1,1000) error_msg,
               ia.roq_qty orig_qty, isc.inner_pack_size
          FROM zms_ifi_ia_alloc_roq_ext ia, pid_sku_master psm,
               item_master im, zms_ifi_ia_alloc_roq roq,
               zms_all_location zal1, zms_all_location zal2,
               zms_ia_activate_parms iap,
               item_supp_country isc
         WHERE ia.item = psm.sku(+)
           AND ia.item = im.item(+)
           AND psm.initiated_brand     = iap.div(+)
           AND ia.item                 = isc.item(+)
           AND isc.primary_supp_ind    = 'Y'
           AND isc.primary_country_ind = 'Y'
           AND iap.active_ind(+)       = 'Y'
		   AND iap.alloc_roq_ind(+)    = 'Y' --Added by Sagar on 12-Aug-25
           AND CASE WHEN iap.dept(+)     > 0 THEN psm.dept     ELSE 0 END = iap.dept(+)
           AND CASE WHEN iap.class(+)    > 0 THEN psm.class    ELSE 0 END = iap.class(+)
           AND CASE WHEN iap.subclass(+) > 0 THEN psm.subclass ELSE 0 END = iap.subclass(+)
           AND ia.ia_allocation_id     = roq.ia_allocation_id(+)
           AND zal1.loc_four_digit(+)  = CASE WHEN ia.from_loc LIKE 'A%' THEN LPAD(REGEXP_REPLACE(ia.from_loc, '[^[:digit:]]', '' ),4,'0')
                                             ELSE REGEXP_REPLACE(ia.from_loc, '[^[:digit:]]', '' ) END  -- Code change to process Kjo allocation Data.
           AND zal2.loc_four_digit(+) = CASE WHEN ia.to_loc LIKE 'A%' THEN 1||LPAD(REGEXP_REPLACE(ia.to_loc, '[^[:digit:]]', '' ),4,'0')
                                             ELSE REGEXP_REPLACE(ia.to_loc, '[^[:digit:]]', '' ) END) a
         ORDER BY a.store_div, a.from_loc, a.to_loc, a.item;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------

    v_table_name := 'zms_ifi_ia_alloc_roq';
    v_sql_number := '020';

    SELECT count(*) INTO v_alloc_cnt
      FROM zms_ifi_ia_alloc_roq ia
     WHERE ia.process_status = 'N';

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows to process from table '||v_table_name||': '||v_alloc_cnt);

    IF v_alloc_cnt = 0 THEN
       zlog.write_msg(g_debug_lvl,v_sql_number||'. No Data to Process - Records in External Table - '||v_alloc_cnt);
       raise no_data_to_process_1;
    END IF;

    -----------------------------------------------------------------------------------------------
    -- Adjust into table

    v_table_name := 'zms_ifi_ia_alloc_roq';
    v_sql_number := '025';

     MERGE INTO zms_ifi_ia_alloc_roq ia USING
        (SELECT * FROM (
            SELECT ia.ia_allocation_id, ia.from_loc, ils.loc, ils.item, ils.stock_on_hand,
                   ia.intf_date,
                   row_number () OVER(PARTITION BY ils.item ORDER BY ils.stock_on_hand desc) rank
              FROM zms_ifi_ia_alloc_roq ia, item_loc_soh ils, zms_all_location zal
             WHERE ia.process_status = 'N'
               AND zal.loc_type = 'W'
               AND zal.loc = ils.loc
               AND ia.item = ils.item
               AND ils.stock_on_hand > 0)
          WHERE from_loc <> loc
            AND rank = 1
        ) dt
     ON(ia.ia_allocation_id = dt.ia_allocation_id and ia.item = dt.item and ia.intf_date = dt.intf_date)
     WHEN MATCHED THEN
     UPDATE
     SET ia.from_loc = dt.loc;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table 

    v_table_name := 'zms_ifi_ia_alloc_id';
    v_sql_number := '030';

    INSERT INTO zms_ifi_ia_alloc_id
       (div, from_loc, release_date, ia_allocation_id)
    SELECT DISTINCT div, from_loc, release_date, ia_allocation_id
      FROM zms_ifi_ia_alloc_roq ia
     WHERE process_status = 'N'
       AND ia.ia_allocation_id NOT IN (SELECT ia_allocation_id FROM zms_ifi_ia_alloc_id)
     ORDER BY div, from_loc;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows merged into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Update table

    v_table_name := 'zms_ifi_ia_alloc_id';
    v_sql_number := '040';

        UPDATE zms_ifi_ia_alloc_id 
           SET alloc_id = ALC_ALLOC_SEQ.nextval 
         WHERE alloc_id IS NULL
           AND process_status = 'N';
         
    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Records Updated: '||v_process_qty);

    -----------------------------------------------------------------------------------------------

    v_table_name := 'zms_ifi_ia_alloc_roq';
    v_sql_number := '050';

        DBMS_STATS.GATHER_TABLE_STATS(
             ownname          => 'ZMS',
             tabname          => 'zms_ifi_ia_alloc_roq',
             estimate_percent => 99,
             method_opt       => 'for all columns size repeat',
             degree           => 2
           );

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Analyzed');

    -----------------------------------------------------------------------------------------------

    v_table_name := 'zms_ifi_ia_alloc_id';
    v_sql_number := '060';

        DBMS_STATS.GATHER_TABLE_STATS(
             ownname          => 'ZMS',
             tabname          => 'zms_ifi_ia_alloc_id',
             estimate_percent => 99,
             method_opt       => 'for all columns size repeat',
             degree           => 2
           );

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Analyzed');

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alc_alloc';
    v_sql_number := '070';

    INSERT INTO alc_alloc
       (status, alloc_id, 
        alloc_desc, 
        process_status, rule_template_name,
        location_template_name, enforce_wh_store_rel_ind, created_date,
        created_by_user_id, locked_by_user_id, locked_timestamp,
        never_update_group_ind, context, promotion, promo_desc,
        alloc_comment, mld_approval_level, release_date_from_in_store_ind,
        mld_modified_level, parent_id, parent_allocation,
        deaggregated_fashion, non_sell_fashion_pack_only)
    SELECT 4 status, ia.alloc_id, 
           'IA '||ia.div||' '||SUBSTR(ia.from_loc,1,4)||' '||to_char(ia.release_date,'YYYYMMDD') alloc_desc,
           13 process_status, NULL rule_template_name,
           NULL location_template_name, 'N' enforce_wh_store_rel_ind, get_vdate created_date,
           1 created_by_user_id, NULL locked_by_user_id, NULL locked_timestamp,
           'N' never_update_group_ind, NULL context, NULL promotion, NULL promo_desc,
           ia.ia_allocation_id alloc_comment, NULL mld_approval_level, NULL release_date_from_in_store_ind,
           NULL mld_modified_level, NULL parent_id, 'N' parent_allocation, 
           'N' deaggregated_fashion, 'N' non_sell_fashion_pack_only
      FROM zms_ifi_ia_alloc_id ia
     WHERE ia.process_status = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alc_item_loc';
    v_sql_number := '080';

    INSERT INTO alc_item_loc
       (item_loc_id, alloc_id, item_id, wh_id, release_date,
        location_id, location_desc, allocated_qty, calculated_qty,
        need_qty, on_hand_qty, som_qty, freeze_ind, diff1_id,
        diff1_desc, diff2_id, diff2_desc, parent_item_id,
        created_order_no, created_supplier_id, parent_diff1_id,
        future_unit_retail, rush_flag, cost, in_store_date,
        future_on_hand_qty, order_no, gross_need_qty, rloh_qty)
   SELECT alc_item_loc_seq.nextval, ia.alloc_id, roq.item, ia.from_loc, ia.release_date,
          roq.to_loc, s.store_name, roq.roq_qty, roq.roq_qty,
          roq.roq_qty, 0, 1, 'N', NULL,
          NULL, NULL, NULL, roq.item,
          NULL, NULL, NULL,
          0, 'N', 0, ia.release_date + 1,
          0, NULL, roq.roq_qty, 0
     FROM zms_ifi_ia_alloc_id ia, zms_ifi_ia_alloc_roq roq, store s
    WHERE ia.ia_allocation_id = roq.ia_allocation_id
      AND ia.from_loc         = roq.from_loc
      AND ia.release_date     = roq.release_date
      AND roq.to_loc          = s.store
      AND ia.process_status   = 'N'
      AND roq.process_status  = 'N';  -- HH 10/15/24

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alc_item_source';
    v_sql_number := '090';

    INSERT INTO alc_item_source
       (item_source_id, alloc_id, item_id, default_level, pack_ind,
        hold_back_pct_flag, hold_back_value, som_qty, avail_qty,
        release_date, source_type, order_no, wh_id, diff1_id,
        diff1_desc, diff2_id, inner_size, case_size, pallet,
        calc_multiple, on_hand_qty, future_on_hand_qty,
        min_avail_qty, threshold_percent)
    SELECT alc_item_source_seq.nextval, ia.alloc_id, roq.item, 'T', 'N',
           'N', 0, 1, 0,
           ia.release_date, 3, NULL, ia.from_loc, NULL,
           NULL, NULL, NVL(isc.inner_pack_size,1), 1, 1,
           'EA', 0, 0,
           0, 0
      FROM zms_ifi_ia_alloc_id ia, item_supp_country isc, 
           (SELECT DISTINCT ia_allocation_id, release_date, item
              FROM zms_ifi_ia_alloc_roq
             WHERE process_status = 'N') roq
     WHERE ia.ia_allocation_id     = roq.ia_allocation_id
       AND ia.release_date         = roq.release_date
       AND roq.item                = isc.item(+)
       AND isc.primary_supp_ind    = 'Y'
       AND isc.primary_country_ind = 'Y'
       AND ia.process_status       = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alc_xref';
    v_sql_number := '100';

    INSERT INTO alc_xref
       (xref_id, alloc_id, item_id,
        wh_id, release_date,
        parent_item_id, diff1_id,
        order_no, allocated_qty,
        xref_alloc_no, close_ind)
    SELECT
        alc_xref_seq.nextval xref_id, ia.alloc_id, rq.item item_id,
        ia.from_loc wh_id, ia.release_date release_date, NULL parent_item_id,
        NULL diff1_id, NULL order_no, rq.ord_qty allocated_qty,
        alloc_order_sequence.nextval xref_alloc_no, 'N' close_ind
      FROM zms_ifi_ia_alloc_id ia, alc_alloc aa,
           (SELECT div, from_loc, item, release_date, ia_allocation_id, SUM(roq_qty) ord_qty
              FROM zms_ifi_ia_alloc_roq
             WHERE process_status = 'N'
             GROUP BY div, from_loc, item, release_date, ia_allocation_id
             ORDER BY div, item) rq
     WHERE ia.alloc_id = aa.alloc_id
       AND ia.div      = rq.div
       AND ia.from_loc = rq.from_loc
       AND ia.release_date     = rq.release_date
       AND ia.ia_allocation_id = rq.ia_allocation_id
       AND ia.process_status   = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alloc_header';
    v_sql_number := '110';

    INSERT INTO alloc_header
       (alloc_no, order_no, wh, item, status,
        alloc_desc, 
        po_type, alloc_method, release_date, order_type, context_type, 
        context_value, comment_desc, doc, doc_type, alloc_parent)
     SELECT ax.xref_alloc_no alloc_no, NULL order_no, ax.wh_id wh, ax.item_id item, 'A' status,
           'IA '||ia.div||' '||SUBSTR(ia.from_loc,1,4)||' '||to_char(ia.release_date,'YYYYMMDD') alloc_desc,
           NULL po_type, 'A' alloc_method,  ia.release_date, 'AUTOMATIC' order_type, NULL context_type,
           'IA' context_value, ia.ia_allocation_id comment_desc, NULL doc, NULL doc_type, NULL alloc_parent
      FROM alc_xref ax, zms_ifi_ia_alloc_id ia
     WHERE ia.alloc_id     = ax.alloc_id
       AND ia.release_date = ax.release_date
       AND ia.process_status = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------
    -- Insert into table

    v_table_name := 'alloc_detail';
    v_sql_number := '120';

    INSERT INTO alloc_detail
       (alloc_no, to_loc, to_loc_type, qty_transferred, 
        qty_allocated, qty_prescaled, qty_distro, 
        qty_selected, qty_cancelled, qty_received, 
        qty_reconciled, po_rcvd_qty, non_scale_ind, 
        in_store_date, rush_flag)
    SELECT
        ax.xref_alloc_no alloc_no, rq.to_loc, 'S' to_loc_type, 0 qty_transferred,
        SUM(rq.ord_qty) qty_allocated, SUM(rq.ord_qty) qty_prescaled, 0 qty_distro,
        NULL qty_selected, 0 qty_cancelled, NULL qty_received,
        NULL qty_reconciled, NULL po_rcvd_qty, 'Y' non_scale_ind,
        ia.release_date+1 in_store_date, 'N' rush_flag
      FROM alc_xref ax, zms_ifi_ia_alloc_id ia,
           (SELECT div, from_loc, to_loc, release_date, ia_allocation_id, item, SUM(roq_qty) ord_qty
              FROM zms_ifi_ia_alloc_roq
             WHERE process_status = 'N'
             GROUP BY div, from_loc, to_loc, item, release_date, ia_allocation_id) rq
     WHERE ia.alloc_id         = ax.alloc_id
       AND ia.div              = rq.div
       AND ia.from_loc         = rq.from_loc
       AND ia.ia_allocation_id = rq.ia_allocation_id
       AND ia.release_date     = ax.release_date
       AND ax.item_id          = rq.item
       AND ia.process_status   = 'N'
     GROUP BY ax.xref_alloc_no, rq.to_loc, ia.release_date+1;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Total rows inserted into table '||v_table_name||': '||v_process_qty);

    -----------------------------------------------------------------------------------------------

EXCEPTION

  WHEN NO_DATA_TO_PROCESS_1 THEN
    o_rc := 95;
    :ret_code := 95;
    g_err_msg := 'NO ALLOCATIONS FOR TODAY';
    zlog.write_msg(1, g_err_msg);
    dbms_output.put_line(g_err_msg);

  WHEN OTHERS THEN
    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'ROLLBACK');
    zlog.write_error('ROLLBACK');
    ROLLBACK;

END create_allocations;

---------------------------------------------------------------------------------
-- Update item_loc_soh
---------------------------------------------------------------------------------
PROCEDURE update_item_loc_soh(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_procname VARCHAR2(30) := 'update_item_loc_soh';

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

--
-- Update item_loc_soh
--

    -----------------------------------------------------------------------------------------------

    v_table_name := 'item_loc_soh';
    v_sql_number := '130';

     MERGE INTO item_loc_soh ils USING
        (SELECT from_loc, item, SUM(roq_qty) roq_qty
           FROM zms_ifi_ia_alloc_roq ia
          WHERE ia.process_status = 'N'
          GROUP BY ia.from_loc, ia.item) dt
     ON(ils.loc = dt.from_loc and ils.item = dt.item)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_reserved_qty = ils.tsf_reserved_qty + dt.roq_qty;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Records Updated: '||v_process_qty);

    -----------------------------------------------------------------------------------------------

    v_table_name := 'item_loc_soh';
    v_sql_number := '140';

     MERGE INTO item_loc_soh ils USING
        (SELECT to_loc, item, SUM(roq_qty) roq_qty
           FROM zms_ifi_ia_alloc_roq ia
          WHERE ia.process_status = 'N'
          GROUP BY ia.to_loc, ia.item) dt
     ON(ils.loc = dt.to_loc and ils.item = dt.item)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_expected_qty = ils.tsf_expected_qty + dt.roq_qty;

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Records Updated: '||v_process_qty);

    -----------------------------------------------------------------------------------------------

  o_rc := 0;

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to item_loc_soh');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'Procedure ' || l_procname || ' failed to item_loc_soh');
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
--  ROLLBACK;

END update_item_loc_soh;

---------------------------------------------------------------------------------
-- Update process status
---------------------------------------------------------------------------------
PROCEDURE update_process_status(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_procname VARCHAR2(30) := 'update_process_status';

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

--
-- Update process status
--

   -----------------------------------------------------------------------------------------------

    v_table_name := 'zms_ifi_ia_alloc_roq';
    v_sql_number := '150';

        UPDATE zms_ifi_ia_alloc_roq
           SET process_status = 'P',
               process_date   = v_process_date
         WHERE process_status = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Records Updated: '||v_process_qty);

    -----------------------------------------------------------------------------------------------

    v_table_name := 'zms_ifi_ia_alloc_id';
    v_sql_number := '160';

        UPDATE zms_ifi_ia_alloc_id
           SET process_status = 'P',
               process_date   = v_process_date
         WHERE process_status = 'N';

    v_process_qty := SQL%ROWCOUNT;

    zlog.write_msg(g_debug_lvl,v_sql_number||'. Table '||v_table_name||' Records Updated: '||v_process_qty);

  o_rc := 0;

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to update process status');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'Procedure ' || l_procname || ' failed to update process status');
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
--  ROLLBACK;

END update_process_status;

---------------------------------------------------------------------------------
-- Add new item locations
---------------------------------------------------------------------------------
PROCEDURE add_new_item_locations(o_rc IN OUT NUMBER, o_err_msg IN OUT VARCHAR2) IS

  l_procname VARCHAR2(30) := 'add_new_item_locations';
  l_item item_master.item%TYPE;
  l_loc store.store%TYPE;
  l_tot_recs_processed NUMBER;
  l_tot_recs_added NUMBER;
  l_err_code NUMBER;
  l_err_msg VARCHAR2(1000);
  l_tab_err_msg zms_ifi_sa_sales.error_message%TYPE;
  l_step NUMBER := 0;

CURSOR c3 IS
SELECT DISTINCT store, item
  FROM
  (SELECT ia.from_loc store, ia.item
    FROM zms_ifi_ia_alloc_roq ia,
         item_master im
   WHERE ia.process_status = 'N'
     AND ia.item = im.item
     AND NOT EXISTS (SELECT 'x'
                       FROM item_loc il
                      WHERE il.item = ia.item
                        AND il.loc = ia.from_loc)
     UNION
  SELECT ia.to_loc store, ia.item
    FROM zms_ifi_ia_alloc_roq ia,
         item_master im
   WHERE ia.process_status = 'N'
     AND ia.item = im.item
     AND NOT EXISTS (SELECT 'x'
                       FROM item_loc il
                      WHERE il.item = ia.item
                        AND il.loc = ia.to_loc));

BEGIN

  zlog.write_msg(1, 'Started ' || l_procname);

  l_tab_err_msg := NULL;
  l_tot_recs_processed := 0;
  l_tot_recs_added := 0;
  l_err_code := 0;
  l_err_msg := NULL;

  l_step := 1;

    v_table_name := 'zms_new_item_loc';
    v_sql_number := '170';

  FOR c3rec IN c3
  LOOP

    l_item := c3rec.item;
    l_loc := c3rec.store;

    l_tab_err_msg := NULL;
    l_err_code := 0;
    l_err_msg := NULL;

    l_step := 2;
--
-- Trap the failed call to zms_new_item_loc so that we don't exit our loop.
--
    BEGIN

      ZMS_NEW_ITEM_LOC(l_item, l_loc, l_err_code, l_err_msg);

    EXCEPTION

      WHEN OTHERS THEN
        l_tab_err_msg := 'Call to ZMS_NEW_ITEM_LOC error: ' || l_err_code;
        zlog.write_error(l_tab_err_msg);
        zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
        zlog.write_msg(0, l_tab_err_msg);
        zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);

    END;

    IF (l_err_code <> 0)
    THEN
--
-- Rollback any work that zms_new_item_loc completed
--
      l_step := 3;
--    ROLLBACK;

      IF (l_tab_err_msg IS NULL)
      THEN
        l_tab_err_msg := 'ERROR:  Internal call to ZMS_NEW_ITEM_LOC, errcode=' || l_err_code;
        zlog.write_error(l_tab_err_msg || ' ERRMSG: ' || l_err_msg);
        zlog.write_msg(0, l_tab_err_msg || ' ERRMSG: ' || l_err_msg);
      END IF;

    ELSE
      l_tot_recs_added := l_tot_recs_added + 1;
    END IF;

    l_tot_recs_processed := l_tot_recs_processed + 1;

  END LOOP;

  zlog.write_msg(0, 'Added ' || l_tot_recs_added ||
                 ' item/loc records out of ' || l_tot_recs_processed || ' total processed');

  o_rc := 0;

--
-- We should only reach this exception statement with a major Oracle ERROR.
-- This exception statement traps FATAL errors as follows:
-- a) Main Fetch Failure.
-- b) COMMIT/ROLLBACK errors.
--

EXCEPTION

  WHEN OTHERS THEN

    o_rc := sqlcode;
    o_err_msg := sqlerrm;
    zlog.write_error('Procedure ' || l_procname || ' failed to add new items locs at step ' || l_step);
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);
    zlog.write_msg(0, 'Procedure ' || l_procname || ' failed to add new item locs at step ' || l_step);
    zlog.write_msg(0, 'ERROR:  SQLCODE=' || sqlcode || ':' || ' ERRMSG=' || sqlerrm);

    ROLLBACK;

END add_new_item_locations;

---------------------------------------------------------------------------------
-- MAIN PROCESS -----------------------------------------------------------------
---------------------------------------------------------------------------------

BEGIN

--
-- Setup log files.
--

  IF (zlog.initialize(g_err_msg, c_program, 0, g_debug_lvl) = FALSE)
  THEN
    RAISE INIT_LOG_FAIL;
  END IF;

  zlog.write_msg(0, '------------ START ' || c_program || ' -------------');
  zlog.write_log('Started');

  SELECT vdate INTO g_batch_date FROM period;

  create_allocations(g_return_code, g_err_msg);
  IF (g_return_code = 95)
  THEN
    RAISE NO_DATA_TO_PROCESS;
  END IF;
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

--
-- Add item/locs where the item exists in item_master but not in item_loc
-- for the given store.
--

  add_new_item_locations(g_return_code, g_err_msg);
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

--
-- Update item_loc_soh for transfer_reserve and transfer_expected
--

  zlog.write_msg(0, 'Update item_loc_soh');

  update_item_loc_soh(g_return_code, g_err_msg);
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

--
-- Update Process Status
--

  zlog.write_msg(0, 'Update Status');

  update_process_status(g_return_code, g_err_msg);
  IF (g_return_code <> 0)
  THEN
    RAISE FAILED_PROC;
  END IF;

  zlog.write_msg(0, 'Commit');
  COMMIT;

  zlog.write_msg(0, '------------ FINISHED ' || c_program || ' -------------');
  zlog.write_log('Terminated successfully');

  IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
  THEN
    RAISE CLOSE_LOG_FAIL;
  END IF;

---------------------------------------------------------------------------------
-- EXCEPTION PROCESSING ---------------------------------------------------------
---------------------------------------------------------------------------------

EXCEPTION

  WHEN NO_DATA_TO_PROCESS THEN
    :ret_code := 95;
    g_err_msg := 'NO ALLOCATIONS FOR TODAY';
    zlog.write_msg(1, g_err_msg);
    dbms_output.put_line(g_err_msg);

  WHEN INIT_LOG_FAIL THEN
    dbms_output.put_line('ERROR:  Failed to init logs, ERRMSG=' || g_err_msg);
    RAISE;

  WHEN CLOSE_LOG_FAIL THEN
    dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    RAISE;

  WHEN FAILED_PROC THEN
    ROLLBACK;
    zlog.write_error('FAIL_PROC');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
    THEN
     dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    END IF;
    RAISE;

  WHEN OTHERS THEN
    ROLLBACK;
    zlog.write_error('OTHERS');
    zlog.write_error('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    dbms_output.put_line('ERROR:  SQLCODE=' || sqlcode || ':' || 'ERRMSG=' || sqlerrm);
    IF (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
    THEN
     dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
    END IF;
    RAISE;

END;
/

exit
