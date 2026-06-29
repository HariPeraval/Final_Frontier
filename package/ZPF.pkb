CREATE OR REPLACE PACKAGE BODY ZMS.zpf IS

---------------------------------------------------------------------------------
-- GLOBAL VARIABLE DECLARATIONS 
---------------------------------------------------------------------------------7
  --Logging global variables
  g_log_fdir  VARCHAR2(50):='LOGDIR';
  g_log_fname VARCHAR2(50):='zms_zl_pick.log';
  g_log_fptr  utl_file.file_type;
/*********************************************************************/
/* PACKAGE BODY: zpf                                                 */
/* DESCRIPTION: does all of the processing needed to perform a pick  */
/*********************************************************************/
   TYPE pick_days_type IS TABLE OF
      VARCHAR2(8)
      INDEX BY BINARY_INTEGER;
/*********************************************************************/
/* module level variables                                            */
/*********************************************************************/
   /******************************************************************/
   /* save results for next time, then return the results            */
   /******************************************************************/
   m_last_override_sku ITEM_MASTER.ITEM%TYPE;
   m_last_override_sku_return BOOLEAN;
   m_last_override_store STORE.STORE%TYPE;
   m_last_override_store_return BOOLEAN;
   m_last_override_division DIVISION.DIVISION%TYPE;
   m_last_override_wh WH.WH%TYPE;
   m_last_override_dept DEPS.DEPT%TYPE;
   m_last_override_class CLASS.CLASS%TYPE;
   m_last_override_subclass SUBCLASS.SUBCLASS%TYPE;
   m_last_override_dept_return BOOLEAN;
   m_last_watch_ind_div DIVISION.DIVISION%TYPE;
   m_last_watch_indicator_wh WH.WH%TYPE;
   m_last_watch_indicator_dept DEPS.DEPT%TYPE;
   m_last_watch_indicator_class CLASS.CLASS%TYPE;
   m_last_watch_indicator NUMBER;
   m_day_for_pick NUMBER := NULL;
   /******************************************************************/
   /* for a given division, the pick days will be indexed via        */
   /* division number.  for example m_pick_days(10) would be the     */
   /* pick days for the Zale division days 1-7 in characters 1-7 of  */
   /* the string, plus the watch priority  indicator as the eighth   */
   /* character.                                                     */
   /******************************************************************/
   m_pick_days pick_days_type;
   m_substr_for_watch NUMBER := 8;
   /******************************************************************/
   /* for a given division, the dept for watches is XX13, where XX   */
   /* is division specific.  We will use the MOD function to         */
   /* eliminate the XX so we can check the 13 and see that it is     */
   /* a watch dept.  Class 85 is attachments.  In the watch dept     */
   /* these don't count as watches                                   */
   /******************************************************************/
   m_watch_dept_modulus NUMBER := 13;
   m_attachment_class NUMBER := 85;
/*********************************************************************/
/* local function declarations                                       */
/* ######  #######  #####  #          #    ######  #######           */
/* #     # #       #     # #         # #   #     # #                 */
/* #     # #       #       #        #   #  #     # #                 */
/* #     # #####   #       #       #     # ######  #####             */
/* #     # #       #       #       ####### #   #   #                 */
/* #     # #       #     # #       #     # #    #  #                 */
/* ######  #######  #####  ####### #     # #     # #######           */
/*********************************************************************/

   PROCEDURE P_ZPF_Vdate_To_Pick_Dow;
   FUNCTION f_zpf_get_pick_day(pm_division IN NUMBER,
                           pm_wh       IN NUMBER,
                           pm_dept     IN NUMBER,
                           pm_class    IN NUMBER,
                           pm_watch_indicator OUT NUMBER)
   RETURN BOOLEAN;
   FUNCTION f_zpf_get_watch_indicator(pm_division IN NUMBER,
                                  pm_wh       IN NUMBER,
                                  pm_dept     IN NUMBER,
                                  pm_class    IN NUMBER)
   RETURN NUMBER;
   PROCEDURE p_zpf_fix_nopick_sku_group;
/*********************************************************************/
/* actual local function/procedure code                              */
/* #####   #####      #    #    #    ##     #####  ######            */
/* #    #  #    #     #    #    #   #  #      #    #                 */
/* #    #  #    #     #    #    #  #    #     #    #####             */
/* #####   #####      #    #    #  ######     #    #                 */
/* #       #   #      #     #  #   #    #     #    #                 */
/* #       #    #     #      ##    #    #     #    ######            */
/*********************************************************************/
/*********************************************************************/
/* LOCAL PROCEDURE: p_zpf_fix_nopick_sku_group                       */
/* DESCRIPTION: fixes the sku, retail, and cost fields for nopick    */
/*    report records that were excluded due to department etcetera.  */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* IR     | Modification                                             */
/*********************************************************************/
PROCEDURE p_zpf_fix_nopick_sku_group IS
   l_repl_sku_group ZMS_ZPF_NOPICK_REPORT.REPL_SKU_GROUP%TYPE;
   l_division DIVISION.DIVISION%TYPE;
   l_store STORE.STORE%TYPE;
   l_sku ITEM_MASTER.ITEM%TYPE;
   l_unit_cost ZMS_ZPF_NOPICK_REPORT.UNIT_COST%TYPE;
   l_unit_retail ZMS_ZPF_NOPICK_REPORT.UNIT_RETAIL%TYPE;
   l_pick_priority SUB_ITEMS_DETAIL.PICK_PRIORITY%TYPE;

   CURSOR c_nopick_report IS
   SELECT repl_sku_group,
      DIVISION,
      STORE
   FROM ZMS_ZPF_NOPICK_REPORT
   WHERE SKU = -1
   FOR UPDATE;

   CURSOR c_get_cost_retail IS
   SELECT ia.zms_estimated_landed_cost,
          ia.zms_unit_retail,
          sid.sub_item,
          sid.pick_priority
   FROM item_attributes ia,
       (SELECT item, sub_item, l_store location, pick_priority FROM sub_items_detail WHERE loc_type = 'W'
            UNION
        SELECT item, item sub_item, l_store location, 999 pick_priority FROM sub_items_head) sid
   WHERE sid.item     = l_repl_sku_group
     AND sid.location = l_store
     AND ia.item      = sid.item
   ORDER BY sid.pick_priority;

--sa   FROM win_skus w,
--sa      ZALE_REPL_SKU_GROUP_DETAIL zrsgd,
--sa      ZALE_STORE_PZONE zsp,
--sa      ZALE_SKU_PZONE zskp
--sa   WHERE zrsgd.repl_sku_group = l_repl_sku_group
--sa   AND w.item = zrsgd.SKU
--sa   AND w.item = zskp.SKU
--sa   AND zsp.DIVISION = l_division
--sa   AND zsp.STORE = l_store
--sa   ORDER BY zrsgd.repl_priority;

BEGIN
   /******************************************************************/
   /* loop through all repl_sku_group records that have not been     */
   /* modified to have a sku                                         */
   /******************************************************************/
   FOR l_nopick_report IN c_nopick_report LOOP
      /***************************************************************/
      /* any sku in the sku group would do for cost and retail       */
      /* purposes, but we chose the one with the lowest number       */
      /* priority.  By doing the order by, we get around the         */
      /* possibility that priority 1 does not exist.                 */
      /***************************************************************/
      l_repl_sku_group := l_nopick_report.repl_sku_group;
      l_store := l_nopick_report.STORE;
      l_division := l_nopick_report.DIVISION;
      OPEN c_get_cost_retail;
      FETCH c_get_cost_retail
      INTO l_unit_cost,
           l_unit_retail,
           l_sku,
           l_pick_priority;
      IF (c_get_cost_retail%NOTFOUND) THEN
         l_unit_cost := 0;
         l_unit_retail := 0;
      END IF;
      CLOSE c_get_cost_retail;
      /***************************************************************/
      /* now we need to update the nopick report based on what we    */
      /* have found                                                  */
      /***************************************************************/
      UPDATE ZMS_ZPF_NOPICK_REPORT
      SET unit_cost   = l_unit_cost,
          unit_retail = l_unit_retail,
          SKU         = l_sku
      WHERE CURRENT OF c_nopick_report;
   END LOOP;
END;

/*********************************************************************/
PROCEDURE p_zpf_scarce_resources_ctl(O_err_code OUT INTEGER) IS

   l_orig_wh    ZMS_ZPF_DIV_EXTRACT.WH%TYPE;
   l_process_no ZMS_ZPF_DIV_EXTRACT.ORD_QTY%TYPE;
   l_pick_wh    ZMS_ZPF_DIV_EXTRACT.WH%TYPE;
   l_prev_wh    ZMS_ZPF_DIV_EXTRACT.WH%TYPE;
   O_error_message  VARCHAR2(2000);
   scarce_resource_error EXCEPTION;

CURSOR c_get_wh_ctl IS
SELECT orig_wh, process_no, pick_wh, prev_wh
  FROM zms_zpf_wh_control zwc
 WHERE zwc.active_flag = 'Y'
 ORDER BY zwc.div, process_no;

BEGIN
   /******************************************************************/
   /******************************************************************/

     g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_zpf_scarce_resources_ctl started:'));

    FOR i_wh_ctl IN c_get_wh_ctl
    LOOP
        l_orig_wh   := i_wh_ctl.orig_wh;
        l_process_no:= i_wh_ctl.process_no;
        l_pick_wh   := i_wh_ctl.pick_wh;
        l_prev_wh   := i_wh_ctl.prev_wh;

       utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - SCARCE_RESOURCES - ZMS_ZPF_WH_CONTROL Pick Ctl: Orig_WH: '|| l_orig_wh ||' - Process_No '|| l_process_no ||' - Pick_WH '|| l_pick_wh ||' - Prev_WH '|| NVL(l_prev_wh,0) ||' '));
       utl_file.fflush(g_log_fptr);
       p_zpf_alloc_scarce_resources(l_orig_wh, l_process_no, l_pick_wh, l_prev_wh, O_err_code);

       IF O_err_code != 0 THEN
          RAISE SCARCE_RESOURCE_ERROR;
       END IF;

    END LOOP;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_zpf_scarce_resources_ctl done:'));
     utl_file.put_line(g_log_fptr,'====================================================================');
     utl_file.fflush(g_log_fptr);
     utl_file.fclose(g_log_fptr);


EXCEPTION

   WHEN SCARCE_RESOURCE_ERROR THEN
        O_error_message := SQLERRM || ' problem in p_zpf_scarce_resources_ctl';
        O_err_code := 20101;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_scarce_resources_ctl';
        O_err_code := 20101;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

END p_zpf_scarce_resources_ctl;

/*********************************************************************/
/* LOCAL PROCEDURE: p_zpf_alloc_scarce_resources                     */
/* DESCRIPTION: This procedure goes through all of the requested     */
/*    SKUs(not belonging to a sku group) and checks the requested    */
/*    quantity versus the available quantity at the warehouse.  We   */
/*    will pick the SKUs based on the following priorities:          */
/*    1. distribution type priority based on zale_dist_type table    */
/*    2. stores with 0 stock on hand                                 */
/*    3. stores with the greatest differential between on hand and   */
/*       model stock                                                 */
/*    4. stores with least stock on hand                             */
/*    5. store group                                                 */
/*    6. requisition number(to try and evenly distribute among       */
/*       stores)                                                     */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/* 1177|Fixed order by to include priority based on dist type and    */
/*     |   repl_store_group                                          */
/*     |   The priority is now:                                      */
/*     | 1. distribution type priority based on zale_dist_type table */
/*     | 2. out of stock                                             */
/*     | 3. highest demand                                           */
/*     | 4. least stock                                              */
/*     | 5. replenishment store group                                */
/*     | 6. requisition (to try and evenly distribute to stores)     */
/*     | LCB 6 February, 1997                                        */
/* ================================================================= */
/* unkn|Unnumbered IR from the DBAs to improve performance.  Removed */
/*     | sort by store group added above.  The priority is now:      */
/*     | 1. distribution type priority based on zale_dist_type table */
/*     | 2. out of stock                                             */
/*     | 3. highest demand                                           */
/*     | 4. least stock                                              */
/*     | 5. requisition (to try and evenly distribute to stores)     */
/*     | LCB 12 March, 1997                                          */
/* 143 | Rewritten the procedure to implement the new scarce resource */
/*       alorithm
/*********************************************************************/
PROCEDURE P_ZPF_ALLOC_scarce_resources (l_ctl_orig_wh    IN NUMBER,
                                        l_ctl_process_no IN NUMBER,
                                        l_ctl_pick_wh    IN NUMBER,
                                        l_ctl_prev_wh    IN NUMBER,
                                        O_err_code      OUT INTEGER) IS
   fptr  utl_file.file_type;
   char_sku VARCHAR2(10);
   char_max_available VARCHAR2(10);
   char_loop VARCHAR2(4);
   c_num_del_skus VARCHAR2(4);
   l_num_del_skus NUMBER := 0;
   l_sku item_master.item%TYPE;
   l_max_available NUMBER;
   l_current_dist_qty NUMBER;
   l_count NUMBER;
   l_boolean BOOLEAN;
   l_wh NUMBER;
   l_pack_size NUMBER;
   l_do_nothing NUMBER := 0;
   O_error_message  VARCHAR2(2000);

   TYPE st_rowid IS TABLE OF
   ROWID
   INDEX BY BINARY_INTEGER;
   TYPE st_dist_qty IS TABLE OF

  NUMBER
   INDEX BY BINARY_INTEGER;
   m_rowid st_rowid;
   m_dist_qty st_dist_qty;
   i BINARY_INTEGER := 0;
   j BINARY_INTEGER := 0;
   l_loop NUMBER := 1;
   tot_stores  NUMBER;

  CURSOR c_skus IS
  SELECT zpf.sku,
         SUM(zpf.ord_qty) req_qty,
         COUNT(*) tot_num,
         zpf.wh
    FROM ZMS_ZPF_DIV_EXTRACT zpf
   WHERE zpf.wh      = l_ctl_pick_wh
     AND zpf.orig_wh = l_ctl_orig_wh
     AND zpf.repl_sku_group = -1
   GROUP BY zpf.SKU, zpf.WH;

   CURSOR c_max_available IS
--sa   SELECT NVL(a.stock_avail,0) , NVL(b.st_pack_size,1)
   SELECT NVL(a.stock_avail,0) , NVL(b.inner_pack_size,1)
     FROM zms_ZPF_WIN_WH a, item_supp_country b
    WHERE a.WH  = l_wh        --IN (SELECT WH FROM WH WHERE wh_type_no = 0)   --WH = 8904
      AND a.SKU = l_sku
      AND a.SKU = b.item
      AND b.primary_supp_ind = 'Y'
      AND b.primary_country_ind = 'Y';

   /******************************************************************/
   /* this cursor helps me decide who gets stock when the requests   */
   /* exceed the stock at the warehouse.  First priority is          */
   /* those stores that are out of stock.  We get this by the decode */
   /* statement that returns an 'A' if the store is out of stock and */
   /* a 'B' if the store has any stock.  Second priority is those    */
   /* with the greatest differential between need and on_hand.  This */
   /* is captured by the second part of the order by clause 'z.ord_  */
   /* qty DESC.'  The third priority is stock on hand ascending.     */
   /* This is captured by the third part of the order by clause      */
   /* 'z.stock_on_hand.' Past that, we sort by request then store in */
   /* order to hopefully evenly distribute among stores.             */
   /*                                                                */
   /* Appendix A - We are checking here to see if this is one of the priority */
   /* stores,  if so then the goal is to give them the ord_qty but   */
   /* depends if we have that much available in the DC, if so then   */
   /* we give it all ord_qty otherwise we give as much as available  */
   /******************************************************************/
/*FCHK6.SQL */
   CURSOR c_single_sku IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.WH,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          z.ord_qty,
          z.ROWID myrow,NVL(zdt.fill_to_model,'N') fill_to_model
   FROM ZMS_ZPF_DIV_EXTRACT z,
        ZMS_ZALE_DIST_TYPE zdt
   WHERE zdt.DIVISION  = z.DIVISION
     AND zdt.dist_type = z.dist_type
     AND z.SKU     = l_sku
     AND z.WH      = l_wh
     AND z.orig_wh = l_ctl_orig_wh
   ORDER BY z.priority,
            out_of_stock,
            z.store_priority,
            z.ord_qty DESC,
            z.stock_on_hand,
            z.REQ,
            z.store;

   CURSOR c_nofill_sku IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.WH,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          z.ord_qty,
          z.ROWID myrow,
          NVL(zdt.fill_to_model,'N') fill_to_model, z.store_priority
   FROM ZMS_ZPF_DIV_EXTRACT z,
        ZMS_ZALE_DIST_TYPE zdt
   WHERE zdt.DIVISION  = z.DIVISION
     AND zdt.dist_type = z.dist_type
     AND z.SKU     = l_sku
     AND z.WH      = l_wh
     AND z.orig_wh = l_ctl_orig_wh
     AND NVL(zdt.fill_to_model,'N') = 'N'
   ORDER BY z.SKU,
            z.priority,
            out_of_stock,
            z.store_priority,
            z.ord_qty DESC,
            z.stock_on_hand,
            z.REQ,
            z.store;
BEGIN

      /************************************************************
      Delete all those recs which have no stock
      ***************************************************************/
-- Akron
--     DELETE FROM ZMS_ZPF_DIV_EXTRACT Zpf
--     WHERE EXISTS (SELECT SKU
--                     FROM ZMS_ZPF_WIN_WH wwz
--                    WHERE Zpf.SKU = wwz.SKU
--                      AND wwz.WH  = Zpf.WH --wwz.WH = 8904
--                      AND stock_avail <= 0);

--     COMMIT;

      /************************************************************
      Akron. Insert Records for Next WH Run
      ***************************************************************/

     g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
     fptr := utl_file.fopen(g_log_fdir,'zms_zl_pick_scarce_sku.log','A');

      IF NVL(l_ctl_prev_wh,0) <> 0 THEN

         INSERT INTO zms_zpf_div_extract
            (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority, in_str_date,
             priority, repl_sku_group, watch_priority, dist_type, wh, request_sku, stock_on_hand,
             stock_avail, move_order_id, alloc_id, distro_date, cust_name, orig_wh, orig_ord_qty,
             orig_req, orig_po_type, pick_process_nbr)
         SELECT zpf.store, sku, zpf.req, po_line_nbr, po_type, division, orig_ord_qty - ord_qty ord_qty, store_priority, in_str_date,
                priority, repl_sku_group, watch_priority, dist_type, l_ctl_pick_wh, zpf.request_sku, stock_on_hand + ord_qty,
                stock_avail, move_order_id, alloc_id, distro_date, cust_name, orig_wh, orig_ord_qty - ord_qty orig_ord_qty,
                zpf.req, po_type, 0 pick_process_nbr
           FROM zms_zpf_div_extract zpf
          WHERE zpf.orig_ord_qty - zpf.ord_qty > 0
            AND zpf.orig_wh        = l_ctl_orig_wh
            AND zpf.wh             = l_ctl_prev_wh
            AND zpf.repl_sku_group = -1;

        utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - Create Next WH DIV Extract - '||l_ctl_pick_wh||' - '||SQL%ROWCOUNT));

        COMMIT;

        INSERT INTO zms_zpf_div_extract_bk
           (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
            in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
            request_sku, stock_on_hand, move_order_id,
            stock_avail, distro_date, cust_name, alloc_id,
            process_type, process_date, orig_wh, orig_ord_qty,
            orig_req, orig_po_type, pick_process_nbr)
         SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
                in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
                request_sku, stock_on_hand + ord_qty, move_order_id,
                stock_avail, distro_date, cust_name, alloc_id,
                'Pick5' process_type, sysdate process_date, orig_wh, orig_ord_qty,
                orig_req, orig_po_type, pick_process_nbr
           FROM zms_zpf_div_extract zpf
          WHERE zpf.wh  = l_ctl_pick_wh
            AND zpf.wh <> orig_wh
            AND zpf.repl_sku_group = -1;

        utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - Backup Process_Type 5: '||l_ctl_pick_wh||'  '||SQL%ROWCOUNT));

        COMMIT;

     END IF;

     -- Set ord_qty = 0 and pick_process_nbr = 1 when the warehouse is not scheduled to pick
     UPDATE zms_zpf_div_extract zpf
        SET zpf.ord_qty          = 0,
            zpf.pick_process_nbr = 1
      WHERE zpf.wh              = l_ctl_pick_wh
        AND zpf.orig_wh         = l_ctl_orig_wh
        AND zpf.repl_sku_group  = -1
        AND zpf.wh NOT IN (SELECT DISTINCT wh FROM zms_zpf_pick_day_stores);

    -- Set ord_qty = 0 when the warehouse does not have inventory
--     MERGE INTO zms_zpf_div_extract zpf USING
--       (SELECT DISTINCT zpf.wh, zpf.orig_wh, zpf.sku
--           FROM zms_zpf_div_extract zpf, zms_zpf_win_wh zwh, item_supp_country isc
--          WHERE zpf.sku     = zwh.sku(+)
--            AND zpf.wh      = zwh.wh(+)
--            AND zpf.sku     = isc.item
--            AND zpf.wh      = l_ctl_pick_wh
--            AND zpf.orig_wh = l_ctl_orig_wh
--            AND zpf.repl_sku_group      = -1
--            AND NVL(zwh.stock_avail,0)  < NVL(isc.inner_pack_size,0)
--            AND isc.primary_supp_ind    = 'Y'
--            AND isc.primary_country_ind = 'Y') dt
--     ON(zpf.wh = dt.wh and zpf.orig_wh = dt.orig_wh and zpf.sku = dt.sku)
--     WHEN MATCHED THEN UPDATE
--        SET zpf.ord_qty          = 0,
--            zpf.pick_process_nbr = 1;

     COMMIT;

   /*************************************************************
    This is valid because even if we have to restart the program
    those reqs with zero stock would not matter
    ***************************************************************/
   /******************************************************************/
   /* loop through distinct non-replenishment sku group skus in      */
   /* today's requisitions.  We get a summation of the qty requested */
   /* for the sku.                                                   */
   /******************************************************************/

     utl_file.putf(fptr,(TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - Create Next WH DIV Extract - '||l_ctl_pick_wh||'  Orig_WH '||l_ctl_orig_wh||'\n'));
     utl_file.fflush(fptr);

     FOR l_skus IN c_skus
     LOOP

        char_sku := TO_CHAR(l_skus.SKU);
        tot_stores := l_skus.tot_num;
        utl_file.putf(fptr,'Processing WH/Sku %s\n',l_ctl_pick_wh||' '||char_sku);
        utl_file.fflush(fptr);
      /***************************************************************/
      /* get the amount of stock from the warehouse                  */
      /***************************************************************/
        l_sku := l_skus.SKU;
        l_wh  := l_skus.WH;
        l_max_available := 0;
        l_pack_size     := 1;
        OPEN c_max_available;
        FETCH c_max_available
        INTO l_max_available, l_pack_size;
--sa        IF (c_max_available%NOTFOUND) THEN
--sa         l_boolean := Stack.f_push ('SKU:'||TO_CHAR (l_sku)||
--sa            ' on a Requisition But not in win_wh.');
--sa        END IF;
        CLOSE c_max_available;
        IF l_max_available >= l_pack_size THEN        -- J.P. 102006
            l_max_available := l_max_available - MOD(l_max_available,l_pack_size);
        ELSE
            l_max_available := 0;
        END IF;
        --IF (l_max_available < 0) THEN
         --l_max_available := 0;
        --END IF;
      /***************************************************************/
      /* IF (there is no stock at the warehouse) then                */
      /*    delete all records with that sku since we can't pick     */
      /*    what we don't have                                       */
      /***************************************************************/
        IF (l_max_available = 0) THEN

        --Akron - Keep records for next CTL Loop
           UPDATE ZMS_ZPF_DIV_EXTRACT zpf
              SET zpf.ord_qty          = 0,
                  zpf.pick_process_nbr = 1
            WHERE zpf.SKU     = l_sku
              AND zpf.wh      = l_ctl_pick_wh
              AND zpf.orig_wh = l_ctl_orig_wh;

        --Akron - Keep records for next CTL Loop
        -- DELETE FROM ZMS_ZPF_DIV_EXTRACT
        --  WHERE SKU = l_sku
        --    AND WH  = l_wh;
        --Akron
        -- DELETE ZMS_ZPF_NOPICK_REPORT
        --  WHERE SKU = l_sku
        --    AND reason_code IS NULL;
      /***************************************************************/
      /* the second problem that can occur is that requests exceed   */
      /* warehouse stock.  Since we can't pick more than is there    */
      /* we want to limit the pick quantity to what is there.        */
      /***************************************************************/
        ELSIF (l_skus.req_qty > l_max_available) THEN
         l_current_dist_qty := 0;
         /************************************************************/
         /* loop through all requisitions lines for the current sku  */
         /************************************************************/
         i:= 0;
         FOR l_single_sku IN c_single_sku
         LOOP
            char_sku := TO_CHAR(l_single_sku.SKU);
            /*********************************************************/
            /* IF (we have already hit the max quantity we can       */
            /*    distribute) the delete the current record since we */
            /*    cannot fill it                                     */
            /*********************************************************/
            IF (l_current_dist_qty >= l_max_available ) THEN
               --Akron Update
                 UPDATE zms_zpf_div_extract
                    SET ord_qty     = 0,
                        pick_process_nbr = 1
                  WHERE ROWID = l_single_sku.myrow;

               --Akron
               --DELETE FROM ZMS_ZPF_DIV_EXTRACT
               --WHERE ROWID = l_single_sku.myrow;

               --DELETE ZMS_ZPF_NOPICK_REPORT
               -- WHERE REQ = l_single_sku.REQ
               --   AND SKU = l_single_sku.SKU
               --   AND repl_sku_group = -1
               --   AND STORE = l_single_sku.STORE;
            /*********************************************************/
            /* else(there is some qty left to distribute) so        */
            /*********************************************************/
            ELSE
               /******************************************************/
               /* IF (the requested quantity is more than what is    */
               /*    left) then change the req qty to what is left   */
               /******************************************************/
               IF (l_single_sku.ord_qty > (l_max_available - l_current_dist_qty)) THEN
                 IF l_single_sku.fill_to_model = 'Y' THEN
                  UPDATE ZMS_ZPF_DIV_EXTRACT
                     SET ord_qty     = (l_max_available - l_current_dist_qty),
                         stock_avail = (l_max_available - l_current_dist_qty),
                         pick_process_nbr = 1
                   WHERE ROWID = l_single_sku.myrow;

                  l_current_dist_qty := l_max_available ;

                 END IF; /* End if Fill to model = Y */
                 IF l_single_sku.fill_to_model = 'N' THEN
                   i := i+1;
                   m_rowid(i) := l_single_sku.myrow;
                   m_dist_qty(i) := l_pack_size;  -- J.P. added to adjust to a package size 102006  --1;
                   l_current_dist_qty := l_current_dist_qty + l_pack_size; -- 1;  -- J.P.
                 END IF;
               /******************************************************/
               /* else(there is as much or more left than the       */
               /*    current request) so add to the current          */
               /*    distributed amount the amount of this request   */
               /*    line                                            */
               /******************************************************/
               ELSE
                 IF l_single_sku.fill_to_model = 'Y' THEN
                  l_current_dist_qty := l_current_dist_qty + l_single_sku.ord_qty;
                 ELSE
                  i := i+1;
                  m_rowid(i) := l_single_sku.myrow;
                  m_dist_qty(i) := l_pack_size;  --1; -- J.P.
                  l_current_dist_qty := l_current_dist_qty + l_pack_size;  --1;  -- J.P. added to adjust to a package size 102006
                 END IF;
               /******************************************************/
               /* end IF (the requested quantity is more than what is*/
               /*    left)                                           */
               /******************************************************/
               END IF;  -- l_single_sku.ord_qty
            /*********************************************************/
            /* end IF (we have already hit the max quantity we can   */
            /*    distribute)                                        */
            /*********************************************************/
            END IF; -- l_current_dist_qty
            char_loop := TO_CHAR(i);
         /************************************************************/
         /* end loop through all requisitions lines for the curnt sku*/
         /************************************************************/
         END LOOP; -- l_single_sku
         IF (l_max_available - l_current_dist_qty) <= 0 THEN
           l_loop := 0;
         ELSE
           l_loop := 1;
         END IF;
         LOOP
         EXIT WHEN l_loop = 0;
           l_count := 0;
           FOR l_nofill_sku IN c_nofill_sku
           LOOP
             IF l_current_dist_qty >= l_max_available  THEN
               EXIT;
             END IF;
             j := 0;
             LOOP
             j := j+1; /*Index starts with 1 */

             EXIT WHEN j > i;
              IF (m_rowid(j) = l_nofill_sku.myrow) THEN
               IF m_dist_qty(j) < l_nofill_sku.ord_qty THEN
                 IF l_nofill_sku.store_priority <>  0 THEN -- see explanation labelled as 'APPENDIX A' above
                  /* If l_nofill_sku.sku = 14991640 and l_nofill_sku.store = 2872 then
                   char_max_available := to_char(l_max_available);
                 utl_file.putf(fptr,'Processing Sku in nofill  %s\n',char_sku);
                 utl_file.putf(fptr,'store is   %s\n',l_nofill_sku.store);
                 utl_file.putf(fptr,'m dist qty  is   %s\n',m_dist_qty(j));
                 utl_file.putf(fptr,'l max available %s\n',char_max_available);
                 utl_file.putf(fptr,'current dist qty is    %s\n',l_current_dist_qty);
                 utl_file.fflush(fptr);
              end if; */
                  IF (l_max_available - l_current_dist_qty) >= (l_nofill_sku.ord_qty - m_dist_qty(j)) THEN
                   l_current_dist_qty := l_current_dist_qty + (l_nofill_sku.ord_qty - m_dist_qty(j));
                   m_dist_qty(j) := m_dist_qty(j) + (l_nofill_sku.ord_qty - m_dist_qty(j));
                  ELSE
                   m_dist_qty(j) := m_dist_qty(j) + (l_max_available - l_current_dist_qty);
                   l_current_dist_qty := l_current_dist_qty + (l_max_available  - l_current_dist_qty);

                  /* If l_nofill_sku.sku = 14991640 and l_nofill_sku.store = 2872 then
                   char_max_available := to_char(l_max_available);
                 utl_file.putf(fptr,'Processing Sku where max is not enuf  %s\n',char_sku);
                 utl_file.putf(fptr,'store is   %s\n',l_nofill_sku.store);
                 utl_file.putf(fptr,'m dist qty  is   %s\n',m_dist_qty(j));
                 utl_file.putf(fptr,'l max available %s\n',char_max_available);
                 utl_file.putf(fptr,'current dist qty is    %s\n',l_current_dist_qty);
                 utl_file.fflush(fptr);
              end if;  */

                  END IF;
                 ELSE
                   m_dist_qty(j)      := m_dist_qty(j)+ l_pack_size;
                   l_current_dist_qty := l_current_dist_qty + l_pack_size;
                 END IF;
               END IF;
               EXIT;
              END IF;
             END LOOP;
             j:= 0;
             l_count := l_count + 1;
           END LOOP;/* l_nofill_sku*/
   /*******TOOK OUT B/C IT DELETED TOO MUCH****************************
   if l_count != tot_stores then
     DELETE FROM zms_zpf_div_extract
     WHERE SKU = l_sku;
     l_current_dist_qty := 0;
     l_num_del_skus := l_num_del_skus +1;
     c_num_del_skus := to_char(l_num_del_skus);
     i := 0;
   utl_file.putf(fptr,'Record in zms_zpf_div_extract was deleted for sku %s %s\n',ch
ar_sku, c_num_del_skus);

   utl_file.fflush(fptr);
   l_loop := 0;
   end if;    if l_count ....
   *******************************************************************/
           IF l_current_dist_qty >= l_max_available THEN
            l_loop := 0;
           END IF;
         END LOOP; -- l_loop
         j := 0;
         FOR j IN 1..i
         LOOP
           UPDATE ZMS_ZPF_DIV_EXTRACT
              SET ord_qty      = m_dist_qty(j),
              stock_avail      = (l_max_available - l_current_dist_qty),
              pick_process_nbr = 1
            WHERE ROWID = m_rowid(j);
         END LOOP;

         j:= 0;
      /***************************************************************/
      /* end IF (there is no stock at the warehouse)                 */
      /***************************************************************/
        ELSE
          l_current_dist_qty := l_skus.req_qty;
        END IF;  -- l_max_available
   /******************************************************************/
   /* end loop through distinct non-replenishment sku group skus in  */
   /* today's requisitions.                                          */
   /******************************************************************/
        UPDATE ZMS_ZPF_WIN_WH
           SET STOCK_AVAIL = NVL(STOCK_AVAIL,0)- l_current_dist_qty
         WHERE WH  = l_wh  --WH = 8904
           AND SKU = l_sku;

        l_current_dist_qty := 0;

        UPDATE zms_zpf_div_extract zpf
           SET pick_process_nbr  = 1
          WHERE zpf.sku     = l_sku
            AND zpf.wh      = l_ctl_pick_wh
            AND zpf.orig_wh = l_ctl_orig_wh
            AND zpf.pick_process_nbr    <> 1
            AND zpf.repl_sku_group      = -1;

     END LOOP; -- l_skus
     utl_file.putf(fptr,'I am Done!! ,bye\n');
     utl_file.fflush(fptr);
     utl_file.fclose(fptr);
     utl_file.put_line(g_log_fptr,'====================================================================');
--     utl_file.fflush(g_log_fptr);
--     utl_file.fclose(g_log_fptr);
   /* Update zl_process_extract_check.SKU_PROC to 'Y' if this procedure is
      finished successfully   added by Prasad */

--   UPDATE ZL_PROCESS_EXTRACT_CHECK SET SKU_PROC = 'Y' ;
-- Akron
-- COMMIT;

EXCEPTION

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_scarce_resources';
        O_err_code := 20102;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

END p_zpf_alloc_scarce_resources;
/*********************************************************************/
/* LOCAL FUNCTION: f_zpf_get_watch_indicator                         */
/* DESCRIPTION: Retrieves the watch indicator from the zpf_dcs_div   */
/*    table based on division.  The watch indicator can only be true */
/*    for the watch department(XX13) where the class is no 85        */
/*    attachments.                                                   */
/* RETURNS:                                                          */
/*    pm_watch_indicator - 0 - watch indicator not set               */
/*       1 - watch indicator set                                     */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*********************************************************************/
FUNCTION f_zpf_get_watch_indicator(pm_division IN NUMBER,
                               pm_wh       IN NUMBER,
                               pm_dept IN NUMBER,
                               pm_class IN NUMBER)
RETURN NUMBER IS
   l_return_value NUMBER;
   CURSOR c_get_watch_indicator IS
   SELECT DECODE(watch_yn,'Y', 1, 0) watch_indicator
     FROM ZMS_ZPF_DCS_DIV
    WHERE DIVISION = pm_division
      AND WH       = pm_wh;
BEGIN
   /******************************************************************/
   /* IF (the current division/dept/class are the same as the        */
   /*    previous call) then return the same value, saving           */
   /*    opening/closing a cursor                                    */
   /******************************************************************/
   IF((NVL(m_last_watch_ind_div,-1) = pm_division) AND
      (NVL(m_last_watch_indicator_wh,-1) = pm_wh) AND
      (NVL(m_last_watch_indicator_dept,-1) = pm_dept) AND
      (NVL(m_last_watch_indicator_class,-1) = pm_class)) THEN
      l_return_value := m_last_watch_indicator;
   /******************************************************************/
   /* we only need to check the watch indicator for the watch dept   */
   /* where the class is not attachments                             */
   /* The watch dept is XX13 where XX is division specific.  The XX  */
   /* can be eliminated from the equasion by using the modulus       */
   /* function.  If the remainder of mod(dept,1000) is 13, we are in */
   /* the watch dept for that division.  If the class is 85, that    */
   /* means attachments.  Attachments don't count as watches.        */
   /******************************************************************/
   ELSIF ((MOD(pm_dept,1000) = m_watch_dept_modulus) AND
         (pm_class != m_attachment_class)) THEN
      OPEN c_get_watch_indicator;
      FETCH c_get_watch_indicator
       INTO l_return_value;
      IF (c_get_watch_indicator%NOTFOUND) THEN
         l_return_value := 0;
      END IF;
      CLOSE c_get_watch_indicator;
   /******************************************************************/
   /* else(this is not the same as the last call and we are not     */
   /*    in the watch dept) so watch indicator is automatically 0    */
   /******************************************************************/
   ELSE
      l_return_value := 0;
   END IF;
   m_last_watch_ind_div := pm_division;
   m_last_watch_indicator_wh := pm_wh;
   m_last_watch_indicator_dept := pm_dept;
   m_last_watch_indicator_class := pm_class;
   m_last_watch_indicator := l_return_value;
   RETURN(l_return_value);
END f_zpf_get_watch_indicator;
/*********************************************************************/
/* LOCAL PROCEDURE: p_zpf_vdate_to_pick_dow                          */
/* DESCRIPTION: Who picks depends on the the day of the week.  We    */
/*    start with the vdate and add one day to that since the pick    */
/*    will be for tomorrow.  We then convert that to a number one to */
/*    seven representing the days of the week Sunday = 1 and Saturday*/
/*    = 7.  Zale weeks start with Monday = 1, therefore we need to   */
/*    reduce the day by one.  If that makes the day of the week zero */
/*    that corresponds to Sunday which is Zale day of the week seven.*/
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*********************************************************************/
PROCEDURE P_ZPF_Vdate_To_Pick_Dow IS
BEGIN
   /***************************************************************/
   /* this converts the current processing date into tommorrow    */
   /*(get_vdate + 1--tomorrow is the day for the pick) then      */
   /* converts it to a number for the day of to week('D')        */
   /***************************************************************/
   m_day_for_pick := TO_NUMBER(TO_CHAR(Get_Vdate + 1, 'D'));
   /***************************************************************/
   /* Oracle weeks start with Sunday, just like God does.  Zale   */
   /* weeks start on Monday.  Therefore, we need to convert for   */
   /* the difference in start of the week.                        */
   /***************************************************************/
   m_day_for_pick := m_day_for_pick - 1;
   IF (m_day_for_pick = 0) THEN
      m_day_for_pick := 7;
   END IF;
END P_ZPF_Vdate_To_Pick_Dow;
/*********************************************************************/
/* LOCAL FUNCTION: f_zpf_get_pick_day                                */
/* DESCRIPTION: The Pick schedules for a week are saved in 8         */
/*    8 character strings where the first seven correspond to the    */
/*    days of the week and the eight corresponds to the watch        */
/*    indicator.  The Zale week begins on Monday, therefore the      */
/*    pick string for the Zale division might look like 'YNNYNNNY'.  */
/*    That would mean pick days are Monday and Thursday with Watch   */
/*    indicator on.  The pick strings are saved and we check for     */
/*    the correct department and class before setting the watch      */
/*    indicator.                                                     */
/* RETURNS: TRUE - means it is the pick day                          */
/*       FALSE - means it is not the pick day                        */
/*    pm_watch_indicator - 0 - watch indicator not set               */
/*       1 - watch indicator set                                     */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*********************************************************************/
FUNCTION f_zpf_get_pick_day(pm_division IN NUMBER,
                        pm_wh       IN NUMBER,
                        pm_dept     IN NUMBER,
                        pm_class    IN NUMBER,
                        pm_watch_indicator OUT NUMBER)
RETURN BOOLEAN IS
   l_return_value BOOLEAN;

   CURSOR c_get_pick_days IS
   SELECT day_1||day_2||day_3||day_4||day_5||day_6||day_7||
          watch_yn
     FROM ZMS_ZPF_DCS_DIV
    WHERE DIVISION = pm_division
      AND WH = pm_wh;
BEGIN
   /******************************************************************/
   /* IF (we have not yet gotten a pick schedule for this div) then  */
   /*    go get it                                                   */
   /******************************************************************/
   OPEN c_get_pick_days;
   FETCH c_get_pick_days
    INTO m_pick_days(pm_division);
--   CLOSE c_get_pick_days;
   IF (c_get_pick_days%NOTFOUND) THEN
         CLOSE c_get_pick_days;
         RAISE_APPLICATION_ERROR(-20100,
            'No Pick Schedule Found for Division '||
            TO_CHAR(pm_division)||',wharehouse '||TO_CHAR(pm_wh));
   END IF;
   CLOSE c_get_pick_days;

   /******************************************************************/
   /* the watch indicator is the eighth character of the m_pick_days */
   /* string for a division.  If it is set to 'Y', set the output    */
   /* watch indicator to 1                                           */
   /******************************************************************/
   pm_watch_indicator := 0;
   IF (SUBSTR(m_pick_days(pm_division),m_substr_for_watch,1) = 'Y') THEN

      /***************************************************************/
      /* we only need to check the watch indicator for the watch dept*/
      /* where the class is not attachments                          */
      /* The watch dept is XX13 where XX is division specific.  The  */
      /* XX can be eliminated from the equasion by using the modulus */
      /* function.  If the remainder of mod(dept,1000) is 13, we are */
      /* in the watch dept for that division.  If the class is 85,   */
      /* that means attachments.  Attachments don't count as watches.*/
      /***************************************************************/
      IF ((MOD(pm_dept,1000) = m_watch_dept_modulus) AND
          (pm_class != m_attachment_class)) THEN
         pm_watch_indicator := 1;
      END IF;
   END IF;
   /******************************************************************/
   /* the day of the week for the next pick in Zale days is stored in*/
   /* m_day_for pick.  If it is currently null, we haven't set it so */
   /* we first call p_vdate_to_pick_dow                              */
   /******************************************************************/
   IF (m_day_for_pick IS NULL) THEN
      P_ZPF_Vdate_To_Pick_Dow;
   END IF;
   l_return_value := FALSE;
   IF (SUBSTR(m_pick_days(pm_division), m_day_for_pick, 1) = 'Y') THEN
      l_return_value := TRUE;
   END IF;
   RETURN(l_return_value);
END f_zpf_get_pick_day;
/*********************************************************************/
/* public functions and procedures                                   */
/* #####   #    #  #####   #          #     ####                     */
/* #    #  #    #  #    #  #          #    #    #                    */
/* #    #  #    #  #####   #          #    #                         */
/* #####   #    #  #    #  #          #    #                         */
/* #       #    #  #    #  #          #    #    #                    */
 /*#        ####   #####   ######     #     ####                     */
/*********************************************************************/
/*********************************************************************/
/* PUBLIC FUNCTION: f_zpf_get_store_group                            */
/* DESCRIPTION: retrieves the replenishment store group for a given  */
/*    deparment, class, subclass, store combination.  If the record  */
/*    does not exist, we return a ZZ.  This function exists because  */
/*    I can't figure out how to get non-existent records through an  */
/*    outer join in the scarce resource algorithm                    */
/* RETURNS repl_store_group - if it exists                           */
/*    'ZZ' if it doesn't                                             */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* IR    | Modifications                                             */
/* ==================================================================*/
/*********************************************************************/
FUNCTION F_ZPF_Get_Store_Group(pm_dept IN NUMBER,
                           pm_class IN NUMBER,
                           pm_subclass IN NUMBER,
                           pm_store IN NUMBER)
RETURN VARCHAR2 IS
-- Procedure not used; Commented out

--sa   l_repl_store_group ZALE_REPL_STORE_GROUP_DETAIL.repl_store_group%TYPE;
        l_repl_store_group sub_items_detail.item%TYPE;
   CURSOR c_store_group IS
       SELECT 'X' FROM dual;

/*
--sa   SELECT repl_store_group
   SELECT sid.item
--sa     FROM ZALE_REPL_STORE_GROUP_DETAIL
     FROM sub_items_detail sid,
          item_master im
    WHERE sid.item     = im.item
      AND im.dept      = pm_dept
      AND im.CLASS     = pm_class
      AND im.SUBCLASS  = pm_subclass
--sa      AND STORE = pm_store;
      AND sid.location = pm_store;
*/

BEGIN

   OPEN c_store_group;
/*
   FETCH c_store_group
   INTO l_repl_store_group;

   IF (c_store_group%NOTFOUND) THEN
      l_repl_store_group := 'ZZ';
   END IF;
   CLOSE c_store_group;
   RETURN (l_repl_store_group);
*/
END F_ZPF_Get_Store_Group;
/*********************************************************************/
/* PUBLIC PROCEDURE: p_div_extract_init                              */
/* DESCRIPTION: performs initilization of the ZMS_ZPF_DIV_EXTRACT table. */
/*    First, deletes any records present.  Second, loads all         */
/*    requisition lines that are on open requisitions.  Third, it    */
/*    deletes those records that are easy to remove: those with no   */
/*    request quanity and those advertising requisitions that are    */
/*    more than 45 days in advance.                                  */
/* PARAMETERS: p_is_forecast - TRUE if this is a forecast run or     */
/*    false if it is a normal pick filter run                        */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*1571-|added p_is_forecast parameter.  This allows us to use the    */
/*1573 |same code for forecasts as we use for the actual pick filter.*/
/*     |Added "if" block that inserts into ZMS_ZPF_DIV_EXTRACT from      */
/*     |reqdetail.                                                   */
/*Hari |05042026-As per  new enhancement Added new two columns store_group and */
/*      store for tables zms_ifi_pick_sku_override and zms_ifi_pick_dept_override */
/*********************************************************************/
PROCEDURE p_zpf_div_extract_init (p_is_forecast IN BOOLEAN,
                                  O_err_code   OUT INTEGER) IS
   l_number   NUMBER;
   l_vdate    DATE := Get_Vdate;
   l_day      VARCHAR2(3);
   l_sg21     VARCHAR2(30);
   l_sg22     VARCHAR2(30);
   l_sg23     VARCHAR2(30);
   l_sg24     VARCHAR2(30);
   l_sg25     VARCHAR2(30);
   l_sysdate  DATE    := SYSDATE;
   l_pick_cnt NUMBER := 0;
   l_pick_2_cnt  NUMBER := 0;
   l_store_groups   VARCHAR2(1000);
   O_error_message  VARCHAR2(2000);
   no_pick   EXCEPTION;


   CURSOR c_init_pick_days IS
   SELECT DIVISION
     FROM DIVISION;
BEGIN

   g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - init start:'));

    EXECUTE IMMEDIATE 'truncate table zms_zpf_sku_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_dept_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_store_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_pick_day_stores drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_div_extract drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_div_extract_wrk drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_special_sku drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_store_pick_priority drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_main_sub drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_win_wh drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_win_wh1 drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_nopick_report drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_replenishment drop storage';

    EXECUTE IMMEDIATE 'truncate table zms_ppf_sku_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_dept_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_store_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_pick_day_stores drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_div_extract drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_div_extract_wrk drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_special_sku drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_store_pick_priority drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_main_sub drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_win_wh drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_win_wh1 drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_nopick_report drop storage';
    --==== START New Code --05042026====
    EXECUTE IMMEDIATE 'truncate table zms_zpf_sku_store_group_ovrd drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_temp_dept_stor_group_ovrd  drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_sku_str_replenishment drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_sku_PICK_DAY_STORES drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_zpf_sku_store_override drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_ppf_sku_store_override drop storage'; 
    
    EXECUTE IMMEDIATE 'truncate table zms_kjo_win_wh drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_kjo_win_wh1 drop storage'; 
    EXECUTE IMMEDIATE 'truncate table zms_kjo_store_pick_priority drop storage';
    EXECUTE IMMEDIATE 'truncate table zms_kjo_sku_store_override drop storage'; 
    EXECUTE IMMEDIATE 'truncate table zms_kjo_div_extract drop storage';  
    EXECUTE IMMEDIATE 'truncate table zms_kjo_div_extract_bk drop storage';  
    EXECUTE IMMEDIATE 'truncate table zms_kjo_main_sub drop storage';  
    EXECUTE IMMEDIATE 'truncate table zms_kjo_pick_day_stores drop storage';  
    EXECUTE IMMEDIATE 'truncate table zms_kjo_nopick_report drop storage';  	

    --==== END New Code--05042026====
    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Tables Truncated:'));
    utl_file.fflush(g_log_fptr);

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_sku_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_store_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_dept_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_store_group',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_win_wh',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

    UPDATE zms_ifi_pick_sku_override so
       SET so.process_status = 'I'
     WHERE so.process_status = 'N';

    UPDATE zms_ifi_pick_dept_override do
       SET do.process_status = 'I'
     WHERE do.process_status = 'N';

    UPDATE zms_ifi_pick_store_override so
       SET so.process_status = 'I'
     WHERE so.process_status = 'N';

    UPDATE zms_ifi_pick_store_group sg
       SET sg.process_status = 'I'
     WHERE sg.process_status = 'N';
--     AND sg.store_group NOT IN
--            (SELECT store_group
--               FROM rms_replenishment rr, store s
--              WHERE rr.group_name  = sg.store_group
--                AND rr.store       = s.store);

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Set Override Tables Proces_Status to I'));
    utl_file.fflush(g_log_fptr);

    -- store and store group condition added in below sql--05042026

    INSERT INTO zms_zpf_sku_override
        (wh, sku, indicator)
    SELECT DISTINCT so.wh, so.sku, so.indicator
      FROM pid_sku_master pid,
          (SELECT 8591 wh, to_char(sku) sku, indicator FROM can_sku_override
               UNION ALL
           SELECT wh, sku, indicator FROM zms_ifi_pick_sku_override
            WHERE process_status = 'I' and store_group is null and store is null) so             -- Added store and store group conditions--05042026
     WHERE so.sku = pid.sku
     ORDER BY so.wh, so.sku;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Akron Insert into zms_zpf_sku_override Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);
    
    -- store and store group condition added in below sql--05042026
    INSERT INTO zms_zpf_dept_override
        (wh, division, dept, class, subclass, indicator)
    SELECT DISTINCT do.wh, do.division, do.dept, do.class, do.subclass, do.indicator
      FROM (SELECT 8591 wh, division, dept, class, subclass, indicator FROM can_dept_override
               UNION ALL
            SELECT      wh, division, dept, class, subclass, indicator FROM zms_ifi_pick_dept_override 
             WHERE process_status = 'I' and store_group is null and store is null) do,          -- Added store and store group conditions--05042026
            (SELECT * FROM ZMS_ZPF_WH_CONTROL
               UNION ALL
             SELECT * FROM ZMS_PPF_WH_CONTROL
               UNION ALL
             SELECT * from zms_kjo_wh_control) wc
     WHERE do.wh          = wc.pick_wh
       AND wc.active_flag = 'Y'
     ORDER BY do.division, do.dept, do.class, do.subclass;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Akron Insert into zms_zpf_dept_override Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO zms_zpf_store_override
        (wh, store, indicator)
    SELECT DISTINCT so.wh, so.store, so.indicator
      FROM store s,
           (SELECT 8591 wh, store, indicator FROM can_store_override
               UNION ALL
            SELECT      wh, store, indicator FROM zms_ifi_pick_store_override
             WHERE process_status = 'I') so,
           (SELECT * FROM ZMS_ZPF_WH_CONTROL
              UNION ALL
            SELECT * FROM ZMS_PPF_WH_CONTROL
              UNION ALL
            SELECT * from zms_kjo_wh_control) wc
     WHERE so.store = s.store
       AND so.wh    = wc.pick_wh
       AND wc.active_flag = 'Y'
     ORDER BY so.wh, so.store;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Akron Insert into zms_zpf_store_override Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

--    INSERT INTO /*+ APPEND */ zms_zpf_win_wh NOLOGGING
--           (sku, wh, stock_avail)
--       SELECT a.sku, a.wh, a.stock_avail
--         FROM (SELECT wh.sku, wh.wh, wh.stock_avail
--                 FROM zms_ifi_pick_win_wh wh, pid_sku_master psm
--                WHERE wh.sku = psm.sku
--                  AND wh.stock_avail > 0
----                AND psm.initiated_brand <> 150
--                      UNION
--               SELECT wh.sku, wh.wh, wh.stock_avail
--                 FROM zms_win_wh wh
--                WHERE wh.stock_avail > 0) a;
----     ORDER BY sku, wh;
--
--    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Akron Insert into zms_zpf_win_wh Table: '||SQL%ROWCOUNT));
--    utl_file.fflush(g_log_fptr);


    INSERT INTO /*+ APPEND */ zms_zpf_win_wh NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM (SELECT wh.sku, wh.wh, wh.stock_avail
                 FROM zms_ifi_pick_win_wh wh, pid_sku_master psm
                WHERE wh.sku = psm.sku
                  AND wh.stock_avail > 0
--                AND psm.initiated_brand <> 150
                      UNION
               SELECT wh.sku, wh.wh, wh.stock_avail
                 FROM zms_win_wh wh
                WHERE wh.stock_avail > 0) a;
--     ORDER BY sku, wh;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Inventory Insert into zms_zpf_win_wh Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    MERGE INTO zms_zpf_sku_override zso USING
    (SELECT DISTINCT zdd.wh, psm.sku
       FROM zms_zpf_dept_override zdd, pid_sku_master psm
      WHERE psm.initiated_brand = zdd.division
        AND psm.dept      = zdd.dept
        AND psm.CLASS     = NVL(zdd.CLASS,psm.CLASS)
        AND psm.SUBCLASS  = NVL(zdd.SUBCLASS,psm.SUBCLASS)
        AND psm.item_archive_status = 'ACTIVE'
        AND psm.item_status = 'A'
        AND zdd.INDICATOR   = 'Y') dt
    ON(zso.wh = dt.wh and zso.sku = dt.sku and zso.indicator = 'Y')
    WHEN NOT MATCHED THEN INSERT
        (wh, sku, data_source, indicator)
    VALUES (dt.wh, dt.sku, 'OVR', 'Y');

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Merge Dept Overrides into zms_zpf_sku_override Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    MERGE INTO zms_zpf_sku_override zso USING
    (SELECT DISTINCT so.wh, sid.item
       FROM zms_zpf_sku_override so, sub_items_detail sid
      WHERE so.sku = sid.sub_item
        AND indicator = 'Y') dt
    ON(zso.wh = dt.wh and zso.sku = dt.item and zso.indicator = 'Y')
    WHEN NOT MATCHED THEN INSERT
        (wh, sku, data_source, indicator)
    VALUES (dt.wh, dt.item, 'SUB', 'Y');

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Merge Main Skus into zms_zpf_sku_override Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO /*+ APPEND */ zms_zpf_win_wh1 NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM zms_zpf_win_wh a;
--      ORDER BY sku, wh;

    INSERT INTO zms_zpf_win_wh_bk
       (sku, wh, stock_avail, process_type, process_date)
    SELECT sku, wh, stock_avail, 'Pick' process_type, SYSDATE
      FROM zms_zpf_win_wh;


    INSERT INTO /*+ APPEND */ zms_ppf_win_wh NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM zms_zpf_win_wh a;
--      ORDER BY sku, wh;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_ppf_win_wh Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO /*+ APPEND */ zms_ppf_win_wh1 NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM zms_zpf_win_wh a;
--      ORDER BY sku, wh;

    INSERT INTO zms_ppf_win_wh_bk
       (sku, wh, stock_avail, process_type, process_date)
    SELECT sku, wh, stock_avail, 'Pick' process_type, SYSDATE
      FROM zms_ppf_win_wh;

    ----Start kjo Changes-----------------------------

    INSERT INTO /*+ APPEND */ zms_kjo_win_wh NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM zms_zpf_win_wh a;
--      ORDER BY sku, wh;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_kjo_win_wh Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO /*+ APPEND */ zms_kjo_win_wh1 NOLOGGING
           (sku, wh, stock_avail)
       SELECT a.sku, a.wh, a.stock_avail
         FROM zms_zpf_win_wh a;
--      ORDER BY sku, wh;

    INSERT INTO zms_kjo_win_wh_bk
       (sku, wh, stock_avail, process_type, process_date)
    SELECT sku, wh, stock_avail, 'Pick' process_type, SYSDATE
      FROM zms_kjo_win_wh; 

    INSERT INTO zms_kjo_store_pick_priority
        (division, group_name, group_id, store, group_type, creation_date,
         created_by, last_updated_date, last_updated_by, priority_code)
    SELECT division, group_name, group_id, 
          (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store, group_type, creation_date,
           created_by, last_updated_date, last_updated_by, priority_code
      FROM rms_replenishment
     WHERE group_name LIKE 'PICK_DEPT_PRIORITY_%' or
           group_name = 'KJO_PICK_PRIORITY'
     ORDER BY group_name, store, priority_code; 
     
    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_kjo_store_pick_priority Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);
    ----End kjo Changes-----------------------------

    INSERT INTO zms_zpf_store_pick_priority
        (division, group_name, group_id, store, group_type, creation_date,
         created_by, last_updated_date, last_updated_by, priority_code)
    SELECT division, group_name, group_id, 
          (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store, group_type, creation_date,
           created_by, last_updated_date, last_updated_by, priority_code
      FROM rms_replenishment
     WHERE group_name LIKE 'PICK_DEPT_PRIORITY_%' or
           group_name = 'PICK_PRIORITY'
     ORDER BY group_name, store, priority_code;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_zpf_store_pick_priority Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO zms_ppf_store_pick_priority
        (division, group_name, group_id, store, group_type, creation_date,
         created_by, last_updated_date, last_updated_by, priority_code)
    SELECT division, group_name, group_id, 
           (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store, group_type, creation_date,
           created_by, last_updated_date, last_updated_by, priority_code
      FROM rms_replenishment
     WHERE group_name LIKE 'PICK_DEPT_PRIORITY_%' or
           group_name = 'PAGODA_PICK_PRIORITY'
     ORDER BY group_name, store, priority_code;

    --DELETE FROM zms_zpf_win_wh_bk WHERE process_date < SYSDATE - 10;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_ppf_store_pick_priority Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO zms_zpf_main_sub
           (item, sub_item, item_pick_priority)
        SELECT item, sub_item, item_pick_priority
          FROM (SELECT item, sub_item,
                       row_number() OVER (PARTITION BY item
                                              ORDER BY zms_ownership_ind desc, memo_stock_avail desc,
                                                       asset_stock_avail asc, sub_item asc) item_pick_priority
                  FROM ((SELECT ms.item, ms.sub_item, psm.zms_ownership_ind,
                                DECODE(psm.zms_ownership_ind, 'M', NVL(stock_avail,0), -1) memo_stock_avail,
                                DECODE(psm.zms_ownership_ind, 'A', NVL(stock_avail,0), -1) asset_stock_avail,
                                NVL(stock_avail,0) stock_avail
                           FROM pid_sku_master psm,
                                (SELECT sku, SUM(stock_avail) stock_avail FROM zms_zpf_win_wh GROUP BY sku) wh,
                                (SELECT DISTINCT item, sub_item FROM sub_items_detail WHERE loc_type = 'W'
                                        UNION
                                 SELECT DISTINCT item, item sub_item FROM sub_items_head) ms
                          WHERE ms.sub_item = psm.sku
                            AND ms.sub_item = wh.sku(+)))
                          ORDER BY item, item_pick_priority);

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_zpf_main_sub Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    INSERT INTO  /*+ APPEND */ zms_ppf_main_sub NOLOGGING
           (item, sub_item, item_pick_priority)
       (SELECT item, sub_item, item_pick_priority
          FROM zms_zpf_main_sub);

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_ppf_main_sub Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

    ----Start kjo Changes-----------------------------
    INSERT INTO  /*+ APPEND */ zms_kjo_main_sub NOLOGGING
           (item, sub_item, item_pick_priority)
       (SELECT item, sub_item, item_pick_priority
          FROM zms_zpf_main_sub);

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into zms_kjo_main_sub Table: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr); 
    ----End kjo Changes-----------------------------




   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_main_sub',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_win_wh',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_win_wh1',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_store_pick_priority',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ppf_main_sub',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_kjo_main_sub',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ppf_win_wh',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ppf_win_wh1',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_kjo_win_wh',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_kjo_win_wh1',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ppf_store_pick_priority',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_sku_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_dept_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_store_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Analyze Tables'));
    utl_file.fflush(g_log_fptr);

   SELECT SUBSTR(TO_CHAR(vdate+1,'Day'),1,3)
     INTO l_day
     FROM PERIOD;

--l_day := 'Mon';
   /* l_sg1 to l_sg8 is for 8904 */

   /* l_sg21 to l_sg25 is for 8591 */
   IF l_day = 'Mon' THEN
      SELECT mon_sg1,mon_sg2,mon_sg3,mon_sg4,mon_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Tue' THEN
      SELECT tue_sg1,tue_sg2,tue_sg3,tue_sg4,tue_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Wed' THEN
      SELECT wed_sg1,wed_sg2,wed_sg3,wed_sg4,wed_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Thu' THEN
      SELECT thu_sg1,thu_sg2,thu_sg3,thu_sg4,thu_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Fri' THEN
      SELECT Fri_sg1,Fri_sg2,Fri_sg3,Fri_sg4,Fri_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Sat' THEN
      SELECT sat_sg1,sat_sg2,sat_sg3,sat_sg4,sat_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   ELSIF l_day = 'Sun' THEN
      SELECT Sun_sg1,Sun_sg2,Sun_sg3,Sun_sg4,Sun_sg5
      INTO l_sg21,l_sg22,l_sg23,l_sg24,l_sg25
      FROM can_zpf_pick_day;
   END IF;

--   l_sg1:='ZALES-ALL'; l_sg2:='OUTLET-ALL'; l_sg3:='PAGODA-ALL'; l_sg4:='PEOPLES-ALL'; l_sg5:='PEOPLES-ALL';

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    CAN Store Groups Selected for Tonights Pick: '|| l_sg21||' '|| l_sg22||' '|| l_sg23||' '|| l_sg24||' '|| l_sg25||' '));
   utl_file.fflush(g_log_fptr);

--------------------------------

   SELECT LISTAGG (wh||' '||store_group, ', ')
   WITHIN GROUP
   (ORDER BY store_group) store_groups
     INTO l_store_groups
     FROM zms_ifi_pick_store_group
    WHERE process_status   = 'I';

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    AKR Store Groups Selected for Tonights Pick: '|| l_store_groups||' '));
   utl_file.fflush(g_log_fptr);

   INSERT INTO zms_zpf_replenishment
   SELECT division, group_name, group_id, 
          (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store, group_type, creation_date,
          created_by, last_updated_date, last_updated_by, priority_code
     FROM rms_replenishment rr
    WHERE (rr.group_name IN (l_sg21,l_sg22,l_sg23,l_sg24,l_sg25)
             or
           rr.group_name IN (SELECT store_group
                               FROM zms_ifi_pick_store_group
                              WHERE process_status = 'I'));

      dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_replenishment',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   INSERT INTO zms_zpf_PICK_DAY_STORES (STORE, WH, DIV)
   SELECT DISTINCT rr.STORE, wzal.loc_four_digit wh, szal.div
   FROM zms_zpf_replenishment rr, zms_all_location szal,
        (SELECT loc_four_digit FROM zms_all_location
          WHERE loc_type = 'W'
            AND phy_warehouse IS NOT NULL) wzal,
        (SELECT * FROM ZMS_ZPF_WH_CONTROL
            UNION ALL
         SELECT * FROM ZMS_PPF_WH_CONTROL
            UNION ALL
         SELECT * from zms_kjo_wh_control) wc
   WHERE rr.store            = szal.loc_four_digit
     AND wzal.loc_four_digit = wc.pick_wh
     AND wc.pick_wh          = wc.orig_wh
     AND wc.active_flag      = 'Y'
     AND ((rr.group_name IN (l_sg21,l_sg22,l_sg23,l_sg24,l_sg25) and wc.pick_wh = 8591)
             or
          (rr.group_name, wc.pick_wh) IN (SELECT store_group, wh
                                            FROM zms_ifi_pick_store_group
                                           WHERE process_status = 'I'))
   ORDER BY rr.store, wh;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Akron Insert Stores into zms_zpf_PICK_DAY_STORES: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);
   --===================================================================================================================================
   --=====START--New Change added part of Adding new columns in zms_ifi_pick_dept_override and zms_ifi_pick_sku_override tables=========
   --===================================================================================================================================
   --05042026
   
    INSERT INTO zms_zpf_sku_store_group_ovrd
        (wh, sku,store,store_group, indicator  )
    SELECT DISTINCT so.wh, so.sku,so.store,store_group, so.indicator
      FROM pid_sku_master pid,
          (SELECT 8591 wh, to_char(sku) sku, indicator,null store ,null store_group FROM can_sku_override where 1=2
               UNION ALL
           SELECT wh, sku, indicator,store,store_group FROM zms_ifi_pick_sku_override
            WHERE process_status = 'I' and (store is not null or store_group is not null)) so  ,
           (SELECT * FROM ZMS_ZPF_WH_CONTROL
               UNION ALL
            SELECT * FROM ZMS_PPF_WH_CONTROL
               UNION ALL
            SELECT * from zms_kjo_wh_control) wc
     WHERE so.sku = pid.sku
       AND so.wh    = wc.pick_wh
       AND wc.active_flag = 'Y'
     ORDER BY so.wh, so.sku;   

    MERGE INTO zms_zpf_sku_store_group_ovrd zso USING
    (SELECT DISTINCT so.wh, sid.item sku,so.store,so.store_group, so.indicator
       FROM zms_zpf_sku_store_group_ovrd so, sub_items_detail sid
      WHERE so.sku = sid.sub_item
        AND indicator = 'Y') dt
    ON(nvl(zso.store,-1) = nvl(dt.store,-1) and nvl(zso.store_group,'$$') = nvl(dt.store_group,'$$') and zso.wh = dt.wh and zso.sku = dt.sku and zso.indicator = 'Y')
    WHEN NOT MATCHED THEN INSERT
        (wh, sku,store,store_group, data_source, indicator)
    VALUES (dt.wh, dt.sku,dt.store,dt.store_group, 'SUB', 'Y');   
  
    INSERT INTO zms_temp_dept_stor_group_ovrd
               (wh, division, dept, class, subclass,store,store_group, indicator)
    SELECT DISTINCT do.wh, do.division, do.dept, do.class, do.subclass, do.store,do.store_group, do.indicator
      FROM (SELECT 8591 wh, division, dept, class, subclass, indicator,null store,null store_group FROM can_dept_override
               UNION ALL
            SELECT wh, division, dept, class, subclass, indicator,store,store_group FROM zms_ifi_pick_dept_override 
            WHERE process_status = 'I' and (store is not null or store_group is not null)) do,
            (SELECT * FROM ZMS_ZPF_WH_CONTROL
               UNION ALL
             SELECT * FROM ZMS_PPF_WH_CONTROL
               UNION ALL
             SELECT * from zms_kjo_wh_control) wc
     WHERE do.wh          = wc.pick_wh
       AND wc.active_flag = 'Y'
     ORDER BY do.division, do.dept, do.class, do.subclass;  
     
    MERGE INTO zms_zpf_sku_store_group_ovrd zso USING
    (SELECT DISTINCT zdd.wh, psm.sku,zdd.store,zdd.store_group,zdd.indicator
       FROM zms_temp_dept_stor_group_ovrd zdd, 
            pid_sku_master psm
      WHERE psm.initiated_brand = zdd.division
        AND psm.dept      = zdd.dept
        AND psm.CLASS     = NVL(zdd.CLASS,psm.CLASS)
        AND psm.SUBCLASS  = NVL(zdd.SUBCLASS,psm.SUBCLASS)
        AND psm.item_archive_status = 'ACTIVE'
        AND psm.item_status = 'A' 
        ) dt
    ON(zso.wh = dt.wh and zso.sku = dt.sku and   nvl(zso.store,-1) = nvl(dt.store,-1) and nvl(zso.store_group,'$$') = nvl(dt.store_group,'$$'))
    WHEN NOT MATCHED THEN INSERT
        (wh, sku,store,store_group, data_source, indicator)
    VALUES (dt.wh, dt.sku,dt.store,dt.store_group, 'OVR', dt.indicator);  

     delete from zms_zpf_sku_store_group_ovrd b
      where (b.wh,b.sku,b.store,b.store_group) in ( select a.wh,a.sku,a.store,a.store_group 
                                              from zms_zpf_sku_store_group_ovrd a
                                             where store is not null and store_group is not null
                                             group by wh,sku,store,store_group having count(distinct INDICATOR) =2);
     
     delete from zms_zpf_sku_store_group_ovrd b
      where (b.wh,b.sku,b.store ) in ( select a.wh,a.sku,a.store 
                                              from zms_zpf_sku_store_group_ovrd a
                                             where store is not null and store_group is null
                                             group by wh,sku,store having count(distinct INDICATOR) =2);
     
     delete  from zms_zpf_sku_store_group_ovrd b
      where (b.wh,b.sku,b.store_group) in ( select a.wh,a.sku,a.store_group 
                                              from zms_zpf_sku_store_group_ovrd a
                                             where store is null and store_group is not null
                                             group by wh,sku,store,store_group having count(distinct INDICATOR) =2);   

      delete  from zms_zpf_sku_store_group_ovrd  where INDICATOR='N'; 


   INSERT INTO zms_zpf_sku_str_replenishment
   SELECT distinct division, group_name, group_id, 
          (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store, group_type, creation_date,
          created_by, last_updated_date, last_updated_by, priority_code
     FROM rms_replenishment rr
    WHERE rr.group_name IN (SELECT distinct STORE_GROUP FROM zms_zpf_sku_store_group_ovrd where STORE_GROUP is not null);   
 
 INSERT INTO zms_zpf_sku_PICK_DAY_STORES (STORE, WH, DIV,store_group)
   SELECT rr.STORE, szsgo.wh wh, szal.div,rr.group_name
   FROM zms_zpf_sku_str_replenishment rr, 
        zms_all_location szal ,
        (SELECT distinct store_group, wh FROM zms_zpf_sku_store_group_ovrd where STORE_GROUP is not null) szsgo, 
        (SELECT loc_four_digit FROM zms_all_location
          WHERE loc_type = 'W'
            AND phy_warehouse IS NOT NULL) wzal,
        (SELECT * FROM ZMS_ZPF_WH_CONTROL
            UNION ALL
         SELECT * FROM ZMS_PPF_WH_CONTROL
            UNION ALL
         SELECT * from zms_kjo_wh_control) wc
   WHERE rr.store            = szal.loc_four_digit 
     and rr.group_name       = szsgo.store_group 
     and wzal.loc_four_digit = szsgo.wh
     AND wzal.loc_four_digit = wc.pick_wh
     AND wc.pick_wh          = wc.orig_wh
     AND wc.active_flag      = 'Y' ;   
 
    INSERT INTO /*+ APPEND */ zms_zpf_sku_store_override NOLOGGING 
               (wh, sku, store,div,data_source,indicator) 
     SELECT zso.wh, zso.sku, zsp.store ,zsp.div,zso.data_source,zso.indicator
       FROM zms_zpf_sku_store_group_ovrd zso,  
            zms_zpf_sku_PICK_DAY_STORES zsp
      WHERE Zso.STORE_GROUP=zsp.STORE_GROUP 
        AND Zso.STORE_GROUP is not null ; 

     MERGE INTO zms_zpf_sku_store_override pds USING
    (SELECT DISTINCT zso.wh, zso.sku, zso.store ,zal.div,zso.data_source,zso.indicator
       FROM zms_zpf_sku_store_group_ovrd zso, zms_all_location zal
      WHERE zso.store     = zal.loc 
        AND Zso.store is not null ) dt
    ON(pds.wh = dt.wh and pds.store = dt.store and  pds.sku = dt.sku  and  pds.div = dt.div)
    WHEN NOT MATCHED THEN 
    INSERT (wh, sku,store, div,data_source, indicator)
    VALUES (dt.wh, dt.sku, dt.store,dt.div,'OVR',dt.indicator); 

    insert into zms_ppf_sku_store_override
    (wh, sku,store, div,data_source, indicator)
    select wh, sku,store, div,data_source, indicator from zms_zpf_sku_store_override;
    
    insert into zms_kjo_sku_store_override
    (wh, sku,store, div,data_source, indicator)
    select wh, sku,store, div,data_source, indicator from zms_zpf_sku_store_override;
    
   --05042026
   --======================================================================================================================================
   --========END--New Change added part of Adding new columns in zms_ifi_pick_dept_override and zms_ifi_pick_sku_override tables===========
   --======================================================================================================================================
   SELECT COUNT(*) INTO l_pick_2_cnt FROM zms_zpf_sku_store_override; --05042026
   SELECT COUNT(*) INTO l_pick_cnt FROM  ZMS_ZPF_PICK_DAY_STORES;

   IF l_pick_cnt = 0 and l_pick_2_cnt=0 THEN  --05042026
      raise no_pick;
   END IF;

    MERGE INTO zms_zpf_pick_day_stores pds USING
    (SELECT DISTINCT zso.wh, zso.store, zal.div
       FROM zms_zpf_store_override zso, zms_all_location zal
      WHERE zso.store     = zal.loc
        AND zso.INDICATOR = 'Y') dt
    ON(pds.wh = dt.wh and pds.store = dt.store)
    WHEN NOT MATCHED THEN INSERT
        (wh, store, div, data_source)
    VALUES (dt.wh, dt.store, dt.div, 'OVR');

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Merge Store Overrides into zms_zpf_PICK_DAY_STORES: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

    MERGE INTO zms_zpf_pick_day_stores pds USING
    (SELECT DISTINCT (case when division in (20,80,90,170) then to_number(1||LPAD(store,4,'0'))  else store  end) store
       FROM rms_replenishment rr
      WHERE group_name LIKE 'FILL_TO_MODEL_%') dt
    ON(pds.store = dt.store)
    WHEN MATCHED THEN UPDATE
    SET dist_type = 'FM';

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Merge dist_type for Fill to Model Stores - zms_zpf_PICK_DAY_STORES: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   INSERT INTO zms_ppf_pick_day_stores
      (wh, store, div, data_source, dist_type)
   SELECT wh, store, div, data_source, dist_type
     FROM zms_zpf_pick_day_stores
    ORDER BY wh, store;
   --kjo Change
   INSERT INTO zms_kjo_pick_day_stores
      (wh, store, div, data_source, dist_type)
   SELECT wh, store, div, data_source, dist_type
     FROM zms_zpf_pick_day_stores
    ORDER BY wh, store;

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_zpf_pick_day_stores',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ppf_pick_day_stores',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );
       
   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_kjo_pick_day_stores',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into table zms_ppf_pick_day_stores   END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert into table zms_kjo_pick_day_stores   END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   INSERT INTO zms_zpf_special_sku
   SELECT sku FROM item_group
   WHERE item_group LIKE 'SPECIAL_SKUS_%';
--   AND division <> 150;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Special Skus    END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   INSERT INTO zms_ifi_pick_win_wh_bk
      (record_id, wh, sku, stock_avail, pick_date, intf_date, process_status,
       processed_date, data_source, error_message, retry_count, workflow_run_id)
   SELECT record_id, wh, sku, stock_avail, pick_date, intf_date, 'P' process_status,
          l_sysdate processed_date, data_source, error_message, retry_count, workflow_run_id
     FROM zms_ifi_pick_win_wh;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Backup zms_ifi_pick_win_wh table    END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   utl_file.put_line(g_log_fptr,'====================================================================');
   utl_file.fflush(g_log_fptr);
   utl_file.fclose(g_log_fptr);


EXCEPTION

   WHEN no_pick THEN

    UPDATE zms_ifi_pick_sku_override so
       SET so.process_status = 'P',
           so.processed_date = SYSDATE
     WHERE so.process_status = 'I';

    UPDATE zms_ifi_pick_dept_override do
       SET do.process_status = 'P',
           do.processed_date = SYSDATE
     WHERE do.process_status = 'I';

    UPDATE zms_ifi_pick_store_override so
       SET so.process_status = 'P',
           so.processed_date = SYSDATE
     WHERE so.process_status = 'I';

    UPDATE zms_ifi_pick_store_group sg
       SET sg.process_status = 'P',
           sg.processed_date = SYSDATE
     WHERE sg.process_status = 'I';

     COMMIT;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Set Override Tables Proces_Status to P'));
    utl_file.fflush(g_log_fptr);

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_sku_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_dept_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_store_override',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ifi_pick_store_group',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 2
       );

        utl_file.put_line(g_log_fptr,('   No Pick - No Stores Groups: '));
        utl_file.put_line(g_log_fptr,'====================================================================');
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);

   O_err_code := 95;

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_div_extract_init';
        O_err_code := 20103;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20103,SQLERRM);

END p_zpf_div_extract_init;

/*********************************************************************/
/*********************************************************************/
PROCEDURE p_zpf_div_extract_ext (p_is_forecast IN BOOLEAN,
                                 O_err_code   OUT INTEGER) IS

   l_ad_type zms_ZALE_DIST_TYPE.dist_type%TYPE := 'VT';
   l_max_ad_date DATE := Get_Vdate + 45;
   l_pick_cnt NUMBER := 0;
   l_pick_2_cnt NUMBER := 0;
   O_error_message  VARCHAR2(2000);


BEGIN

   g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - extract start:'));

   /******************************************************************/
   /* load all requests for skus that are on open transfers          */
   /*
   /******************************************************************/
   --05042026
   
   INSERT /*+ APPEND */ INTO zms_ZPF_DIV_EXTRACT nologging
   (STORE,
    SKU,
    REQ,
    po_line_nbr,
    po_type,
    DIVISION,
    ord_qty,
    store_priority,
    in_str_date,
    distro_date,
    priority,
    repl_sku_group,
    watch_priority,
    dist_type,
    wh,
    request_sku,
    stock_on_hand,
    cust_name,
    orig_wh,
    orig_ord_qty,
    orig_req,
    orig_po_type,
    pick_process_nbr)
   (SELECT --/*+ INDEX(isc PK_ITEM_SUPP_COUNTRY) INDEX(R PK_REQ)*/
       t.to_loc,         --rd.STORE,
--sa10 t.item,           --rd.sku,
       CASE WHEN tsf_type IN ('MR','SO') THEN t.item
            WHEN sid.item IS NULL THEN t.item
            ELSE '-1'
            END SKU, --rd.sku
       --DECODE(sid.item, NULL, t.item,-1), --rd.sku,
       t.tsf_no,         --r.req,
       0   po_line_nbr,
       'T' po_type,              --r.dist_type,
       DECODE(t.initiated_brand,60,60,150,150,20,20,80,80,90,90,170,170,10),
       DECODE(t.ord_qty + (isc.inner_pack_size-MOD(t.ord_qty,isc.inner_pack_size)-isc.inner_pack_size),
          0,isc.inner_pack_size,
          t.ord_qty + (isc.inner_pack_size-MOD(t.ord_qty,isc.inner_pack_size)-isc.inner_pack_size)) ord_qty, --rd.req_qty - rd.pick_qty,
       DECODE(NVL(zal.ups_ind,'N'),'Y', 0,99999) store_priority,
       NULL,             --r.advertising_date,
       vdate distro_date,
       --2,
       zdt.pick_priority,
--sa10       -1, --rd.repl_sku_group,
       CASE WHEN tsf_type IN ('MR','SO') THEN -1
            WHEN sid.item IS NULL THEN -1
            ELSE to_number(t.item)
            END repl_sku_group,
       0 watch_priority,
       --'AP' dist_type,
       zdt.dist_type,
       t.from_loc wh,
       t.item request_sku,
       0 stock_on_hand,
       cust_name,
       substr(t.from_loc,1,4) orig_wh,
       DECODE(t.ord_qty + (isc.inner_pack_size-mod(t.ord_qty,isc.inner_pack_size)-isc.inner_pack_size),
          0,isc.inner_pack_size,
          t.ord_qty + (isc.inner_pack_size-mod(t.ord_qty,isc.inner_pack_size)-isc.inner_pack_size)) orig_ord_qty,  --rd.req_qty - rd.pick_qty,
       t.tsf_no orig_req,         --r.req,
       'T' orig_po_type,
       0   pick_process_nbr
  FROM (SELECT /*+ parallel(th,8) */
               th.tsf_no, th.item, SUBSTR(th.from_loc,1,4) from_loc, th.to_loc,
               th.tsf_type, th.tsf_type_fm, psm.merch_category,
               CASE WHEN tsf_type_fm IS NOT NULL AND psm.merch_category <> 'Clearance' THEN tsf_type_fm
                    ELSE tsf_type
                    END tsf_type_dt,
               th.tsf_qty, th.ship_qty, th.distro_qty, th.cust_name,
               (NVL(th.tsf_qty,0) - NVL(th.ship_qty,0) - NVL(th.distro_qty,0) - NVL(th.cancelled_qty,0)) ord_qty,
               NVL(pds.store, zso.sku) match, get_vdate vdate, psm.initiated_brand
          FROM (SELECT h.tsf_no, SUBSTR(h.from_loc,1,4) from_loc, h.to_loc,
                       CASE WHEN UPPER(SUBSTR(h.comment_desc,1,2)) = 'SO' THEN SUBSTR(h.comment_desc,1,200)
                            ELSE NULL
                            END cust_name,
                       CASE WHEN UPPER(SUBSTR(h.comment_desc,1,2)) = 'SO' THEN 'SO'
                            WHEN h.to_loc IN (SELECT flex_num FROM zms_store_flex_values WHERE flex_type = 'ZPF') THEN 'NT'
                            ELSE DECODE(h.tsf_type,'PL','PL','MR','MR','PL')
                            END tsf_type,
                       CASE WHEN h.to_loc IN (SELECT store FROM zms_zpf_pick_day_stores WHERE dist_type = 'FM') THEN 'FM'
                            ELSE NULL
                            END tsf_type_fm,
                            d.item,d.tsf_qty, d.ship_qty, d.distro_qty,d.cancelled_qty
                  FROM tsfhead h,tsfdetail d
                 WHERE h.status IN ('A','L','S')
                   and h.tsf_no=d.tsf_no
                   AND h.close_date IS NULL
                   AND h.from_loc_type = 'W'
                   AND h.to_loc_type = 'S'
                   AND h.tsf_type NOT IN ('BT','CF')
                   AND ((h.exp_dc_date <= get_vdate + 1)
                       OR (h.tsf_type   = 'PL')
                       OR ((h.tsf_type  = 'MR') AND (h.exp_dc_date IS NULL)))) th,
               --tsfdetail td, 
               zms_zpf_pick_day_stores pds, pid_sku_master psm,
               (SELECT DISTINCT sku FROM zms_zpf_sku_override
                 WHERE indicator = 'Y') zso,
                 zms_zpf_sku_store_override sso
         WHERE th.tsf_no   = th.tsf_no
           AND th.from_loc = pds.wh(+)
           AND th.to_loc   = pds.store(+)
           AND th.item     = zso.sku(+)
           AND th.from_loc = sso.wh(+) 
           AND th.to_loc   = sso.store(+)  
           AND th.item     = sso.sku(+)             
           AND th.item     = psm.sku
           AND NVL(NVL(pds.store, zso.sku),sso.sku) IS NOT NULL
           AND (NVL(th.tsf_qty,0) - NVL(th.ship_qty,0) - NVL(th.distro_qty,0) - NVL(th.cancelled_qty,0)) > 0) t,
         (SELECT DISTINCT item FROM zms_zpf_main_sub) sid,
           --WHERE get_vdate BETWEEN a.start_date and a.end_date) sid,
         item_supp_country isc, zms_ZALE_DIST_TYPE zdt, zms_all_location zal
   WHERE t.item   = sid.item(+)
     AND t.item   = isc.item
     AND t.to_loc = zal.loc
     AND zdt.DIVISION  = zal.store_div
     AND zdt.dist_type = t.tsf_type_dt
     AND isc.primary_supp_ind = 'Y'
     AND isc.primary_country_ind = 'Y');

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    TRANSFERS       END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   /******************************************************************/
   /* load all requests for skus that are on open allocations        */
   /*
   /******************************************************************/
   --05042026
   
   INSERT /*+ APPEND */ INTO ZMS_ZPF_DIV_EXTRACT NOLOGGING
   (STORE,
    SKU,
    REQ,
    po_line_nbr,
    po_type,
    DIVISION,
    ord_qty,
    store_priority,
    in_str_date,
    distro_date,
    priority,
    repl_sku_group,
    watch_priority,
    dist_type,
    wh,
    request_sku,
    stock_on_hand,
    orig_wh,
    orig_ord_qty,
    orig_req,
    orig_po_type,
    pick_process_nbr)
   (SELECT --/*+INDEX(R PK_REQ)*/
       a.to_loc    store,
       a.item      sku,             --rd.sku,
       a.alloc_no  req,             --r.req,
       0           po_line_nbr,
       'A'         po_type,         --r.dist_type,
       im.division,
       DECODE(a.ord_qty + (isc.inner_pack_size-MOD(a.ord_qty,isc.inner_pack_size)-isc.inner_pack_size),
          0,isc.inner_pack_size,
          a.ord_qty + (isc.inner_pack_size-MOD(a.ord_qty,isc.inner_pack_size)-isc.inner_pack_size)) ord_qty, --rd.req_qty - rd.pick_qty,
     --NVL(a.qty_allocated,0) - NVL(a.qty_transferred,0) - NVL(a.qty_distro,0) ord_qty, --rd.req_qty - rd.pick_qty,
       0           store_priority,
       NULL        in_str_date,     --r.advertising_date,
       vdate distro_date,
       --1           priority,
       zdt.pick_priority,
       -1          repl_sku_group,  --rd.repl_sku_group,
       0           watch_priority,
       'MR'        dist_type,       --zdt.dist_type,
       SUBSTR(a.wh,1,4) wh,
       a.item      request_sku,
       0           stock_on_hand,
       substr(a.wh,1,4) wh,
       DECODE(a.ord_qty + (isc.inner_pack_size-MOD(a.ord_qty,isc.inner_pack_size)-isc.inner_pack_size),
          0,isc.inner_pack_size,
          a.ord_qty + (isc.inner_pack_size-MOD(a.ord_qty,isc.inner_pack_size)-isc.inner_pack_size)) orig_ord_qty,
     --NVL(a.qty_allocated,0) - NVL(a.qty_transferred,0) - NVL(a.qty_distro,0) ord_qty,  --rd.req_qty - rd.pick_qty,
       a.alloc_no  req,              --r.req
       'A'         orig_po_type,
       0           pick_process_nbr
    FROM (SELECT --/*+ ORDERED INDEX(ad PK_ALLOC_DETAIL) */
            ah.alloc_no, ah.item, SUBSTR(ah.wh,1,4) wh, ad.to_loc, ad.qty_allocated,
            ad.qty_transferred, ad.qty_distro,
            (NVL(ad.qty_allocated,0) - NVL(ad.qty_transferred,0) - NVL(ad.qty_distro,0)) ord_qty,
            get_vdate vdate
          FROM alloc_header ah, alloc_detail ad
          WHERE ah.status        = 'A' --r.status IN ('O','P') AND
            AND ah.alloc_no      = ad.alloc_no
            AND ah.release_date <= get_vdate + 1
            AND NVL(ad.qty_allocated,0) - NVL(ad.qty_transferred,0) - NVL(ad.qty_distro,0) > 0) a,
         v_item_master im, ZMS_ZALE_DIST_TYPE zdt, zms_zpf_pick_day_stores pds, item_supp_country isc,
         (SELECT DISTINCT sku FROM zms_zpf_sku_override
           WHERE indicator = 'Y') zso,
           zms_zpf_sku_store_override sso
   WHERE a.item   = im.item
   --AND im.division <> 150
     AND zdt.DIVISION  = im.division
     AND zdt.dist_type = 'MR'
     AND a.wh          = pds.wh(+)
     AND a.to_loc      = pds.store(+)
     AND a.item        = zso.sku(+)
     AND a.wh          = sso.wh(+) 
     AND a.to_loc      = sso.store(+)  
     AND a.item        = sso.sku(+)       
     AND a.item        = isc.item
     AND isc.primary_supp_ind = 'Y'
     AND isc.primary_country_ind = 'Y'
     AND nvl(NVL(pds.store, zso.sku),sso.sku) IS NOT NULL);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    ALLOCATIONS     END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ZPF_DIV_EXTRACT',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 30
       );

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    ANALYZE-1       END: '));


       INSERT INTO zms_zpf_div_extract_bk
          (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           process_type, process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr)
       SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
              in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
              request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
              'Pick1' process_type, sysdate process_date, orig_wh, orig_ord_qty,
              orig_req, orig_po_type, pick_process_nbr
         FROM zms_zpf_div_extract WHERE division not in (150,20,80,90,170);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Backup Process_Type Pick1 - zms_zpf_div_extract_bk: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

       INSERT INTO zms_ppf_div_extract_bk
          (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           process_type, process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr)
       SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
              in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
              request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
              'Pick1' process_type, sysdate process_date, orig_wh, orig_ord_qty,
              orig_req, orig_po_type, pick_process_nbr
         FROM zms_zpf_div_extract WHERE division  = 150;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Backup Process_Type Pick1 - zms_ppf_div_extract_bk: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

       INSERT INTO  zms_kjo_div_extract_bk
          (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
           in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
           request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
           process_type, process_date, orig_wh, orig_ord_qty,
           orig_req, orig_po_type, pick_process_nbr)
       SELECT store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority,
              in_str_date, priority, repl_sku_group, watch_priority, dist_type, wh,
              request_sku, stock_on_hand, move_order_id, stock_avail, distro_date, cust_name, alloc_id,
              'Pick1' process_type, sysdate process_date, orig_wh, orig_ord_qty,
              orig_req, orig_po_type, pick_process_nbr
         FROM zms_zpf_div_extract WHERE division  in (20,80,90,170);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Backup Process_Type Pick1 - zms_kjo_div_extract_bk: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;


   --DELETE FROM zms_zpf_div_extract zpf
   -- WHERE sku <> -1
   --   AND (sku,wh) IN (SELECT wh.sku, wh.wh
   --                      FROM zms_zpf_win_wh wh
   --                     WHERE zpf.sku = wh.sku
   --                       AND stock_avail = 0);

-- Akron
   DELETE FROM zms_zpf_div_extract zpf
    WHERE (wh, orig_wh) NOT IN
            (SELECT zwc.pick_wh, zwc.orig_wh FROM ZMS_ZPF_WH_CONTROL zwc
              WHERE zwc.active_flag = 'Y'
               UNION ALL
             SELECT pwc.pick_wh, pwc.orig_wh FROM ZMS_PPF_WH_CONTROL pwc
              WHERE pwc.active_flag = 'Y'  
               UNION ALL
             SELECT kwc.pick_wh, kwc.orig_wh FROM zms_kjo_wh_control kwc
              WHERE kwc.active_flag = 'Y'  );

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Remove WH No Pick: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

-- Akron
   DELETE FROM zms_zpf_div_extract zpf
    WHERE sku <> -1
      AND (sku,division) IN
          (SELECT sku, division FROM
             (SELECT zpf.sku, zpf.division, SUM(NVL(wh.stock_avail,0)) stock_avail
                FROM zms_zpf_win_wh wh, zms_zpf_div_extract zpf
               WHERE zpf.sku = wh.sku(+)
                 AND zpf.sku <> -1
            GROUP BY zpf.sku, zpf.division
              HAVING SUM(NVL(wh.stock_avail,0)) = 0));

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Remove Skus No Stock_Avail: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

--   Trouble Shooting
--   SELECT wh.sku, wh.wh, wh.stock_avail, zpf.* FROM zms_zpf_div_extract zpf, zms_zpf_win_wh wh
--    WHERE zpf.sku <> -1
--      AND wh.sku = zpf.sku
--      AND (zpf.sku,zpf.wh) IN (SELECT wh.sku, wh.wh
--                         FROM zms_zpf_win_wh wh
--                        WHERE zpf.sku = wh.sku
--                          AND stock_avail = 0)
--    ORDER BY wh.sku, wh.wh, zpf.store
--
--   SELECT wh.sku, wh.wh, wh.stock_avail FROM zms_zpf_win_wh wh WHERE sku = 15423544

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   COMMIT;

-- Akron
   --DELETE FROM zms_zpf_div_extract zpf
   -- WHERE sku = -1
   --   AND (repl_sku_group,wh) IN
   --       (SELECT a.repl_sku_group, a.wh
   --          FROM
   --               (SELECT  /*+ parallel(wh,3) parallel(zpf,3) use_hash(z,sid) index(UK_SUB_ITEMS_DETAIL sid) */
   --                        z.repl_sku_group,
   --                        z.wh,
   --                        sum(NVL(wh.stock_avail,0)) stock_avail
   --                  FROM zms_zpf_div_extract z, zms_zpf_win_wh wh,
   --                       (SELECT item, sub_item, SUBSTR(location,1,4) location
   --                          FROM sub_items_detail WHERE loc_type = 'W'
   --                             UNION
   --                        SELECT item, item,    SUBSTR(location,1,4) location
   --                          FROM sub_items_head  WHERE loc_type = 'W') sid
   --                 WHERE z.repl_sku_group = sid.item
   --                   AND sid.sub_item = wh.sku
   --                   AND sid.location = wh.wh
   --                   AND z.sku        = -1
   --                 GROUP BY z.repl_sku_group, z.wh
   --                HAVING sum(NVL(wh.stock_avail,0)) = 0) a
   --          WHERE zpf.repl_sku_group  = a.repl_sku_group);

   DELETE FROM zms_zpf_div_extract zpf
    WHERE sku = -1
      AND (repl_sku_group,division) IN
          (SELECT a.repl_sku_group, a.division
             FROM
                  (SELECT  /*+ parallel(wh,3) parallel(zpf,3) use_hash(z,sid) index(UK_SUB_ITEMS_DETAIL sid) */
                           z.repl_sku_group,
                           z.division,
                           SUM(NVL(wh.stock_avail,0)) stock_avail
                     FROM zms_zpf_win_wh wh, zms_zpf_main_sub zms,
                          (SELECT DISTINCT division, repl_sku_group
                             FROM zms_zpf_div_extract
                            WHERE sku = -1) z
                    WHERE z.repl_sku_group = zms.item
                      AND zms.sub_item     = wh.sku(+)
                    GROUP BY z.repl_sku_group, z.division
                   HAVING SUM(NVL(wh.stock_avail,0)) = 0) a
             WHERE zpf.repl_sku_group  = a.repl_sku_group);

--  Trouble Shooting
--  Select repl_sku_groups with no inventory
--                   SELECT  /*+ parallel(wh,3) parallel(zpf,3) use_hash(z,sid) index(UK_SUB_ITEMS_DETAIL sid) */
--                           z.repl_sku_group,
--                           z.wh,
--                           sum(NVL(wh.stock_avail,0)) stock_avail
--                     FROM zms_zpf_div_extract z, zms_zpf_win_wh wh, zms_zpf_main_sub zms
--                    WHERE z.repl_sku_group = zms.item
--                      AND zms.sub_item = wh.sku
--                      AND z.sku        = -1
--                    GROUP BY z.repl_sku_group, z.wh
--
--  Double Check repl_sku_group to make sure they have no inventory
--                   SELECT  wh.sku, wh.wh, wh.stock_avail, sid.sub_item
--                     FROM zms_zpf_win_wh wh,
--                          (SELECT DISTINCT sub_item FROM zms_zpf_main_sub
--                            WHERE item = '18296327'
--                                  UNION
--                           SELECT '18296327' FROM dual) zms
--                    WHERE zms.sub_item = wh.sku

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Remove Sku Groups No Stock_Avail  END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   dbms_stats.gather_table_stats(
        ownname          => 'ZMS',
        tabname          => 'zms_ZPF_DIV_EXTRACT',
        estimate_percent => 99,
        method_opt       => 'for all columns size repeat',
        degree           => 30
       );

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    ANALYZE-2       END: '));

   INSERT /*+ append */ into zms_zpf_div_extract_wrk nologging
     (sku, store, stock_on_hand)
     SELECT z.sku, z.store, GREATEST(NVL(ils.stock_on_hand,0),0) - GREATEST(NVL(ils.non_sellable_qty,0),0) + GREATEST(NVL(ils.in_transit_qty,0),0)
       FROM (SELECT DISTINCT sku, store, repl_sku_group FROM zms_ZPF_DIV_EXTRACT) z,
            item_loc_soh ils
      WHERE z.sku            = ils.item
        AND z.store          = ils.loc
        AND z.repl_sku_group = -1;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert Into zms_zpf_div_extract_wrk: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   MERGE INTO zms_ZPF_DIV_EXTRACT zpf USING
     (SELECT  wrk.sku, wrk.store, wrk.stock_on_hand
      FROM zms_ZPF_DIV_EXTRACT_wrk wrk
     ) dt
   ON(zpf.sku   = dt.sku    AND
      zpf.store = dt.store)
   WHEN MATCHED THEN
   UPDATE
   SET zpf.stock_on_hand = NVL(dt.stock_on_hand,0);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    SKU_ONHAND      END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT COUNT(*) INTO l_pick_cnt FROM  ZMS_ZPF_DIV_EXTRACT;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   MERGE INTO zms_ZPF_DIV_EXTRACT zpf USING
     (SELECT  /*+ parallel(ils,3) */ --parallel(z,3) use_hash(z,sid) index(UK_SUB_ITEMS_DETAIL sid) */
          z.req, z.repl_sku_group, z.store,
          SUM(GREATEST(NVL(ils.stock_on_hand,0),0) - GREATEST(NVL(ils.non_sellable_qty,0),0) + GREATEST(NVL(ils.in_transit_qty,0),0)) stock_on_hand
        FROM zms_ZPF_DIV_EXTRACT z, item_loc_soh ils, zms_zpf_main_sub zms
       WHERE z.repl_sku_group = zms.item
         AND zms.sub_item     = ils.item
         AND z.store          = ils.loc
         AND z.sku            = -1
       GROUP BY z.req, z.repl_sku_group, z.store) dt
   ON(zpf.repl_sku_group = dt.repl_sku_group AND
      zpf.store = dt.store AND
      zpf.req   = dt.req)
   WHEN MATCHED THEN
   UPDATE
   SET zpf.stock_on_hand = NVL(dt.stock_on_hand,0);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    SUB_SKU_ONHAND  END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   MERGE INTO ZMS_ZPF_DIV_EXTRACT zpf USING
   (SELECT  /*+ parallel(ils,3) */ --parallel(z,3) use_hash(ils, z) */
        z.req, z.repl_sku_group, z.store,
        SUM(GREATEST(NVL(ils.stock_on_hand,0),0) - GREATEST(NVL(ils.non_sellable_qty,0),0) + GREATEST(NVL(ils.in_transit_qty,0),0)) stock_on_hand
      FROM zms_ZPF_DIV_EXTRACT z, item_loc_soh ils
     WHERE z.repl_sku_group = ils.item
       AND z.store          = ils.loc
       AND z.sku            = -1
     GROUP BY z.req, z.repl_sku_group, z.store) dt
   ON(zpf.repl_sku_group = dt.repl_sku_group AND
      zpf.store = dt.store AND
      zpf.req   = dt.req)
   WHEN MATCHED THEN
   UPDATE
   SET zpf.stock_on_hand = NVL(zpf.stock_on_hand,0) + NVL(dt.stock_on_hand,0);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    MAIN_SKU_ONHAND END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   MERGE INTO zms_zpf_div_extract zpf USING
    (SELECT zss.sku, zpf1.store,
            zpf1.req, zdt.pick_priority
       FROM zms_zpf_special_sku zss,
            zms_zpf_div_extract zpf1,
            zms_zale_dist_type zdt
      WHERE zss.sku = zpf1.request_sku
        AND zpf1.stock_on_hand < 0
        AND zpf1.dist_type = 'PL'
        AND zpf1.division = zdt.division
        AND zdt.dist_type = 'NT') dt
   ON(dt.sku   = zpf.request_sku and
      dt.store = zpf.store     and
      dt.req   = zpf.req)
   WHEN MATCHED THEN
   UPDATE
   SET zpf.ord_qty   = zpf.ord_qty + (zpf.stock_on_hand * -1),
       zpf.dist_type = 'NT',
       zpf.priority  = dt.pick_priority;

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Special Sku ord_qty END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

/*********************************************************************/
/* IR#1856 06/20/97. In the above query, added w.sku > 0 and r.req >0*/
/* to force the non-full table scans on the reqdetail and win_skus   */
/* tables.                                 */
/*********************************************************************/

   /******************************************************************/
   /* if (this is a forecast run, not a pick filter run) then include*/
   /*    the req_temp table                                          */
   /*FCHK2.SQL*/
   /******************************************************************/
/*  IF (p_is_forecast) THEN
    INSERT INTO ZMS_ZPF_DIV_EXTRACT
      (STORE,
       SKU,
       REQ,
       po_line_nbr,
       po_type,
       DIVISION,
       ord_qty,
       store_priority,
       in_str_date,
       priority,
       repl_sku_group,
       watch_priority,
       dist_type,
       WH)
      (SELECT /*+INDEX (W PK_WIN_SKUS) / STORE,
         rt.sku,
         999999,
         0,
         'ST',
         g.DIVISION,
         rt.req_qty,
         rt.unit_retail,
         NULL,
         zdt.pick_priority,
         rt.repl_sku_grp,
         0,zdt.dist_type,
         rt.WH
      FROM GROUPS g,DEPS d,REQ_TEMP@over_to_rtkp rt, zms_ZALE_DIST_TYPE zdt,
         item_master w
      WHERE rt.SKU = w.item
      AND w.dept = d.dept
      AND d.group_no = g.group_no
      AND g.DIVISION = zdt.DIVISION
      AND zdt.dist_type = 'ST'
      AND rt.repl_sku_grp = -1
      AND (TO_NUMBER(rt.STORE)  IN
                    (SELECT TO_NUMBER(STORE)
                    FROM zms_zpf_store_override
                    WHERE INDICATOR = 'Y'
                    UNION ALL
                    SELECT DISTINCT rr.STORE
                    FROM rms_replenishment@ rr
                    WHERE group_name IN (l_sg1,l_sg2,l_sg3,l_sg4,l_sg5,l_sg6,l_sg7,l_sg8,l_sg21,l_sg22,l_sg23,l_sg24,l_sg25))
   OR   w.item IN    (SELECT sku FROM zms_zpf_sku_override
                    WHERE INDICATOR = 'Y')
   OR   w.item IN    (SELECT item FROM item_master im
                    WHERE EXISTS (SELECT 'x' FROM zms_zpf_dept_override zdd
                                WHERE im.dept = zdd.dept
                                AND   im.CLASS = NVL(zdd.CLASS,im.CLASS)
                                AND   im.SUBCLASS = NVL(zdd.SUBCLASS,im.SUBCLASS)
                                AND   zdd.INDICATOR = 'Y'))));

*/
/*FCHK3.SQL*/
/*
      INSERT INTO ZMS_ZPF_DIV_EXTRACT
      (STORE,
       SKU,
       REQ,
       po_line_nbr,
       po_type,
       DIVISION,
       ord_qty,
       store_priority,
       in_str_date,
       priority,
       repl_sku_group,
       watch_priority,dist_type)
      (SELECT/*+INDEX (ZRSGH PK_ZALE_REPL_SKU_GROUP_HEAD) / STORE,
         SKU,
         999999,
         0,
         'ST',
         g.DIVISION,
         req_qty,
         unit_retail,
         NULL,
         zdt.pick_priority,
         repl_sku_grp,
         0,zdt.dist_type
      FROM REQ_TEMP@over_to_rtkp rt,
         ZALE_REPL_SKU_GROUP_HEAD@over_to_rtkp zrsgh,
         DEPS d,
         ZMS_ZALE_DIST_TYPE zdt,
         GROUPS g
      WHERE rt.repl_sku_grp = zrsgh.repl_sku_group
      AND zrsgh.dept = d.dept
      AND d.group_no = g.group_no
      AND zdt.DIVISION = g.DIVISION /* Table Join Was Absent /
      AND zdt.dist_type = 'ST'
      AND rt.SKU = -1
      AND (TO_NUMBER(rt.STORE)  IN
                    (SELECT TO_NUMBER(STORE)
                    FROM zms_zpf_store_override
                    WHERE INDICATOR = 'Y'
                    UNION ALL
                    SELECT DISTINCT rr.STORE
                    FROM rms_replenishment rr
                    WHERE group_name IN (l_sg1,l_sg2,l_sg3,l_sg4,l_sg5,l_sg6,l_sg7,l_sg8,l_sg21,l_sg22,l_sg23,l_sg24,l_sg25))
      OR  EXISTS    (SELECT 'x' FROM zms_zpf_dept_override zdd
                                WHERE zrsgh.dept = zdd.dept
                                AND   zrsgh.CLASS = NVL(zdd.CLASS,zrsgh.CLASS)
                                AND   zrsgh.SUBCLASS = NVL(zdd.SUBCLASS,zrsgh.SUBCLASS)
                                AND   zdd.INDICATOR = 'Y')));

   /******************************************************************/
   /* end if (this is a forecast run, not a pick filter run)         */
   /******************************************************************/
--sa   END IF;

   /******************************************************************/
   /* now insert repl_sku_groups from the reqdetail table            */
   /******************************************************************/
   /*FCHK4.SQL*/
/*sa01-start  Combined adding repl_sku_groups above
   INSERT INTO ZPF_DIV_EXTRACT
   (STORE,
    SKU,
    REQ,
    po_line_nbr,
    po_type,
    DIVISION,
    ord_qty,
    store_priority,
    in_str_date,
    priority,
    repl_sku_group,
    watch_priority,
    dist_type,
    WH)
   (SELECT /*+INDEX (R PK_REQ)* /
       rd.STORE,
       rd.SKU,
       r.REQ,
       0,
       r.dist_type,
       g.DIVISION,
       rd.req_qty - rd.pick_qty,
       0,
       r.advertising_date,
       zdt.pick_priority,
       rd.repl_sku_group,
       0,
       zdt.dist_type,
       r.WH
    FROM REQ r,
         REQDETAIL rd,
         DEPS d,
         GROUPS g,
         ZALE_DIST_TYPE zdt,
         ZALE_REPL_SKU_GROUP_HEAD zrsgh
   WHERE r.status IN('O','P')
   AND r.REQ = rd.REQ
   AND r.REQ > 0
   AND r.release_date <= Get_Vdate + 1
   AND rd.sel_for_pick = 'N'
   AND rd.pick_status = 'O'
   AND rd.repl_sku_group = zrsgh.repl_sku_group
   AND zrsgh.dept = d.dept
   AND d.group_no = g.group_no
   AND zdt.DIVISION = g.DIVISION
   AND zdt.dist_type = r.dist_type
   AND (TO_NUMBER(RD.STORE)  IN
                    (SELECT TO_NUMBER(STORE)
                    FROM zms_zpf_store_override
                    WHERE INDICATOR = 'Y'
                    UNION ALL
                    SELECT DISTINCT rr.STORE
                    FROM rms_replenishment rr
                    WHERE group_name IN (l_sg1,l_sg2,l_sg3,l_sg4,l_sg5,l_sg6,l_sg7,l_sg8,l_sg21,l_sg22,l_sg23,l_sg24,l_sg25))
   OR  EXISTS    (SELECT 'x' FROM zms_zpf_dept_override zdd
                                WHERE zrsgh.dept = zdd.dept
                                AND   zrsgh.CLASS = NVL(zdd.CLASS,zrsgh.CLASS)
                                AND   zrsgh.SUBCLASS = NVL(zdd.SUBCLASS,zrsgh.SUBCLASS)
                                AND   zdd.INDICATOR = 'Y')));
*/--sa01_end

   /*********************************************************************/
   /* now copy all of the information to the report table               */
   /* insert into ZMS_ZPF_NOPICK_REPORT only for pick extracts. For forecast*/
   /* No need to touch ZMS_ZPF_NOPICK_REPORT table as per IR#1882           */
   /*********************************************************************/
   IF (NOT p_is_forecast) THEN

   INSERT INTO ZMS_ZPF_NOPICK_REPORT
   (SKU,
      REPL_SKU_GROUP,
      REQ,
      STORE,
      DIVISION,
      DEPT,
      DIST_TYPE,
      UNIT_COST,
      UNIT_RETAIL,
      REQ_QTY,
      PICK_QTY,
      IN_STR_DATE,
      REASON_CODE)
   (SELECT  /*+ RULE */
      z.SKU,
      z.repl_sku_group,
      z.REQ,
      z.STORE,
      z.DIVISION,
      0,
      z.po_type,
      0,
      0,
      NVL(z.ord_qty,0) req_qty,
      NVL(z.ord_qty,0) pick_qty,
      z.in_str_date,
      NULL reason_code
    FROM ZMS_ZPF_DIV_EXTRACT z
   WHERE repl_sku_group = -1);

   END IF;
   COMMIT;

   /******************************************************************/
   /* now exclude those in the nopick->store table                   */
   /******************************************************************/

   DELETE FROM ZMS_ZPF_DIV_EXTRACT zde
   WHERE EXISTS
      (SELECT  'x'
       FROM zms_zpf_store_override zso
       WHERE zso.indicator = 'N'
         AND zso.wh        = zde.wh
         AND zso.store     = zde.store);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Remove Store Overrides END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

   /*********************************************************************/
   /* Update ZMS_ZPF_NOPICK_REPORT only for pick extracts. For forecast     */
   /* No need to touch ZMS_ZPF_NOPICK_REPORT table as per IR#1882           */
   /*********************************************************************/
   IF (NOT p_is_forecast) THEN

   UPDATE ZMS_ZPF_NOPICK_REPORT znr
   SET znr.pick_qty = 0,
       znr.reason_code = 'XSTR'
   WHERE EXISTS
      (SELECT 'x'
       FROM zms_zpf_store_override zso
       WHERE zso.INDICATOR = 'N'
     AND zso.STORE = znr.STORE);

   END IF;
   /******************************************************************/
   /* now clean out those that are easy to exclude: 1. those reqs    */
   /* for advertising where the ad date is more than 45 days away and*/
   /* those reqs for 0 quantity                                      */
   /******************************************************************/

   DELETE FROM ZMS_ZPF_DIV_EXTRACT
   WHERE ord_qty = 0
      OR (NVL(in_str_date,l_max_ad_date) > l_max_ad_date
     AND po_type = l_ad_type);

   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    ord_qty/max_ad_date END: '||SQL%ROWCOUNT));
   utl_file.fflush(g_log_fptr);

   COMMIT;

   SELECT count(*) INTO l_pick_cnt FROM  zms_zpf_div_extract;
   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Records in zms_zpf_div_extract: '||l_pick_cnt));

     /* We are using pick_priority here to set the priority for the stores that
        Are in the priority stores group.  The idea is to make sure that
        We give priority to the stores in the group after the out of stock
        Stores get the inventory. */

     MERGE INTO zms_zpf_div_extract zpf USING
         (SELECT z.store, z.request_sku, z.req, NVL(r.priority_code,99998) priority_code
            FROM zms_zpf_div_extract z, pid_sku_master psm,
                 (SELECT * FROM zms_zpf_store_pick_priority WHERE group_name LIKE 'PICK_DEPT_PRIORITY_%') r
           WHERE z.STORE       = r.STORE
             AND z.request_sku = psm.sku
             AND psm.dept      = SUBSTR(r.group_name,-3)
             AND r.group_name  = 'PICK_DEPT_PRIORITY_'||psm.dept
         ) dt
     ON(zpf.store = dt.store and zpf.request_sku = dt.request_sku and zpf.req = dt.req)
     WHEN MATCHED THEN
     UPDATE
     SET zpf.store_priority = dt.priority_code;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Update Pick Dept Priority: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

     COMMIT;

    MERGE INTO zms_zpf_div_extract zpf USING
         (SELECT z.request_sku, z.store, z.req, NVL(r.priority_code,99998) priority_code
            FROM zms_zpf_div_extract z,
                 (SELECT * FROM zms_zpf_store_pick_priority WHERE group_name = 'PICK_PRIORITY') r
           WHERE z.STORE     = r.STORE
             AND z.division not in (150,20,80,90,170)   --KJO Change
             AND z.store_priority = 99999
         ) dt
     ON(zpf.store = dt.store and zpf.request_sku = dt.request_sku and zpf.req = dt.req)
     WHEN MATCHED THEN
     UPDATE
     SET zpf.store_priority = dt.priority_code;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Update Default Non-Pagoda Store Pick Priority: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

     COMMIT;
    --KJO Change
    MERGE INTO zms_zpf_div_extract zpf USING
         (SELECT z.request_sku, z.store, z.req, NVL(r.priority_code,99998) priority_code
            FROM zms_zpf_div_extract z,
                 (SELECT * FROM zms_kjo_store_pick_priority WHERE group_name = 'KJO_PICK_PRIORITY') r
           WHERE z.STORE     = r.STORE
             AND z.division  in (20,80,90,170)
             AND z.store_priority = 99999
         ) dt
     ON(zpf.store = dt.store and zpf.request_sku = dt.request_sku and zpf.req = dt.req)
     WHEN MATCHED THEN
     UPDATE
     SET zpf.store_priority = dt.priority_code;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Update Default kjo Store Pick Priority: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

     COMMIT;


    MERGE INTO zms_zpf_div_extract zpf USING
         (SELECT z.request_sku, z.store, z.req, NVL(r.priority_code,99998) priority_code
            FROM zms_zpf_div_extract z,
                 (SELECT * FROM zms_ppf_store_pick_priority WHERE group_name = 'PAGODA_PICK_PRIORITY') r
           WHERE z.STORE    = r.STORE
             AND z.division = 150
             AND z.store_priority = 99999
         ) dt
     ON(zpf.store = dt.store and zpf.request_sku = dt.request_sku and zpf.req = dt.req)
     WHEN MATCHED THEN
     UPDATE
     SET zpf.store_priority = dt.priority_code;

    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Update Default Pagoda Store Pick Priority: '||SQL%ROWCOUNT));
    utl_file.fflush(g_log_fptr);

     COMMIT;


   /*********************************************************************/
   /* Update zpf_nopick_report only for pick extracts. For forecast     */
   /* No need to touch zpf_nopick_report table as per IR#1882           */
   /*********************************************************************/
   IF (NOT p_is_forecast) THEN

     DELETE ZMS_ZPF_NOPICK_REPORT
      WHERE req_qty < 1;

     UPDATE ZMS_ZPF_NOPICK_REPORT
        SET pick_qty = 0,
            reason_code = 'ADDAT'
      WHERE (NVL(in_str_date,l_max_ad_date) > l_max_ad_date
        AND dist_type = l_ad_type);

       END IF;

     utl_file.put_line(g_log_fptr,'====================================================================');
     utl_file.fflush(g_log_fptr);
     utl_file.fclose(g_log_fptr);

EXCEPTION

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_div_extract_ext';
        O_err_code := 20104;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20104,SQLERRM);

END p_zpf_div_extract_ext;

/*********************************************************************/
/* PUBLIC PROCEDURE: p_divisional_extract                            */
/* DESCRIPTION: calls two procedures that now do all the work        */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*1571-|Removed the code that processes overrides and put it in      */
/*1573 |p_process_overrides.                                         */
/*1882 |Added boolean argument to p_process_overrides                */
/*      Kishore Kumar 07/01/1997                                     */
/*********************************************************************/
PROCEDURE p_zpf_divisional_extract IS
BEGIN
   /******************************************************************/
   /* call a procedure to do the initial data load                   */
   /******************************************************************/
-- p_zpf_div_extract_init(FALSE);
   /******************************************************************/
   /* commit so we free up rollback segs                             */
   /******************************************************************/
   COMMIT;
   /******************************************************************/
   /* call code to process the overrides                             */
   /******************************************************************/
-- p_zpf_process_overrides(FALSE);
   /******************************************************************/
   /* process requisition lines for scarce resources                 */
   /******************************************************************/
-- p_zpf_alloc_scarce_resources(1,2,3,4);
   /******************************************************************/
   /* commit so we free up rollback segs                             */
   /******************************************************************/
   COMMIT;
END p_zpf_divisional_extract;
/*********************************************************************/
/* PUBLIC PROCEDURE: p_zpf_process_overrides                         */
/* DESCRIPTION: Includes or excludes SKUs for which requisitions     */
/*    exist based on the following criteria:                         */
/* Include:                                                          */
/* 1. pick day for the division for the SKU(zpf_dcs_div)             */
/*    except exclude overrides listed below                          */
/* 2. SKU level override where sku_override.indicator='Y'            */
/* 3. SUBCLASS level override from dept_override where subclass =    */
/*    subclass for the sku and indicator = 'Y'                       */
/* 4. CLASS level override from dept_override where subclass is null */
/*    class = subclass for the sku and indicator = 'Y'               */
/* 5. DEPT level override where dept_override.indicator = 'Y'        */
/*    and subclass and class are NULL                                */
/* 6. STORE level override where store_override.indicator=Y =        */
/*    store for req                                                  */
/*                                                                   */
/* Override Exclude when it is the day for divisional pick           */
/* 1. SKU level override where sku_override.indicator = 'N'          */
/* 2. SUBCLASS level override where sku_override.indicator = 'N'     */
/* 3. CLASS level override where sku_override.indicator = 'N'        */
/*    and subclass is NULL.                                          */
/* 4. DEPT level override where dept_override.indicator = 'N'        */
/*    and subclass and class are NULL.                               */
/* 5. STORE level override where store_override.store = req.store    */
/*    and indicator = 'N'                                            */
/*                                                                   */
/* Prioritization of Include/Exclude for picking is:                 */
/* 1. Store = ?N'                                                    */
/* 2. SKU = ?N'                                                      */
/* 3. Store = ?Y'                                                    */
/* 4. SKU = ?Y'                                                      */
/* 5. Subclass = ?N'                                                 */
/* 6. Subclass = ?Y'                                                 */
/* 7. Class = ?N'                                                    */
/* 8. Class = ?Y'                                                    */
/* 9. Dept = ?N'                                                     */
/* 10. Dept = ?Y'                                                    */
/* 11. Pick Day = ?Y'                                                */
/* 12. Pick Day = ?N'                                                */
/*                                                                   */
/* Once a priority has been met, there need be no further checking.  */
/* In other words, if there is a STORE='N' record, we are through    */
/* checking and need not check the other eleven include/exclude      */
/* criteria.                                                         */
/*                                                                   */
/* To do this, perform the following steps:                          */
/* 1. Pull all open reqdetail skus with sel_for_pick = ?N',          */
/*    pick_status = '?O' or '?P'.  Exclude stores listed in          */
/*    zpf_store_overide where indicator = 'N'.  This takes care of   */
/*    priority 1 above.                                              */
/* 2. Check SKU override in sku_override.  If ?N,' record is excluded.*/
/*    If ?Y,' req record is included.  If record does not exist,     */
/*    continue checking.  This takes care of priorities 2 and 4.     */
/*    Even though we skipped three, that is OK since if we get four  */
/*    then three would make no difference--we would still keep the   */
/*    record.                                                        */
/* 3. Check Store override in store_override.  If record exists      */
/*    in table with ind=Y, req record is included.  If record does   */
/*    not exist in table, continue checking.  This takes care of     */
/*    priority 3.                                                    */
/* 4. Check subclass override in dept_override.  If subclass         */
/*    record = ?N' exclude.  If subclass record = ?Y' include.  If   */
/*    subclass record does not exist, continue checking.  This takes */
/*    care of priorities 5 and 6.                                    */
/* 5. Check class override in dept_override.  If class record = ?N'  */
/*    exclude.  If class record = ?Y' include.  If class record does */
/*    not exist, continue checking.  This takes care of priorities 7 */
/*    and 8.                                                         */
/* 6. Check dept override in dept_override.  If dept record = ?N'    */
/*    exclude.  If dept record = ?Y' include.  If dept record does   */
/*    not exist, continue checking.  This takes care of priorities 9 */
/*    and 10.                                                        */
/* 7. Check divisional pick day for the sku.  If divisional pick     */
/*    day = ?Y' include req record. Otherwise, exclude req record.   */
/*    This takes care of priorities 11 and 12.                       */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/*1571-|Removed from p_divisional_extract so that we can use the     */
/*1573 |same code for for forecast and the real pick filter.  The    */
/*     |code in this procedure is unchanged                          */
/* Modified IR# 1882 : Added boolean argument to p_process_overrides */
/* Kishore Kumar 07/01/1997                                          */
/*********************************************************************/
PROCEDURE p_zpf_process_overrides (p_is_forecast IN BOOLEAN,
                                   O_err_code   OUT INTEGER) IS
   /******************************************************************/
   /* these are really constants                                     */
   /******************************************************************/
   O_error_message         VARCHAR2(2000);
   l_zale_watch_dept       DEPS.DEPT%TYPE := 1013;
   l_zale_watch_attachment CLASS.CLASS%TYPE := 85;
   l_ad_type               ZMS_ZALE_DIST_TYPE.DIST_TYPE%TYPE := 'VT';
   l_pick                  BOOLEAN;
   l_watch_indicator       NUMBER := NULL;
   l_max_pick              item_loc_soh.stock_on_hand%TYPE;
   l_where                 VARCHAR2(2000);
   l_reason_code           ZMS_ZPF_NOPICK_REPORT.REASON_CODE%TYPE;
   l_wh                    WH.WH%TYPE;
   l_override_cnt          NUMBER := 0;
   no_overrides            EXCEPTION;
   l_pick_cnt              NUMBER := 0;

   BEGIN

   g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');

   SELECT sum(row_count) INTO l_override_cnt
     FROM
      (SELECT count(*) row_count FROM zms_zpf_sku_override
        WHERE indicator = 'N'
         UNION ALL
       SELECT count(*) row_count FROM zms_zpf_store_override
        WHERE indicator = 'N'
         UNION ALL
       SELECT count(*) row_count FROM zms_zpf_dept_override
        WHERE indicator = 'N');

   IF l_override_cnt = 0 THEN
      RAISE no_overrides;
   END IF;

  /******************************************************************/
   /* retrieves all req skus after initial extract based on open reqs*/
   /* and first delete on 0 qty and ad date                          */
   /******************************************************************/
   /*FCHK5.SQL*/

    EXECUTE IMMEDIATE 'truncate table zms_zpf_div_overrides';

    INSERT /*+ APPEND */ INTO zms_zpf_div_overrides NOLOGGING
    SELECT * FROM (
       SELECT a.*, skuo.sku           sku_override1,
                   subclasso.subclass subclass_override1,
                   classo.class       class_override1,
                   depto.dept         dept_override1
         FROM
           (SELECT
              z.STORE,
              z.REQUEST_SKU,
              z.REQ,
              z.po_line_nbr,
              z.po_type,
              z.DIVISION,
              z.ord_qty,
              z.store_priority,
              z.in_str_date,
              z.priority,
              z.repl_sku_group,
              z.watch_priority,
              z.WH,
              NVL(im.dept,im1.dept) dept,
              NVL(im.CLASS,im1.CLASS) CLASS,
              NVL(im.SUBCLASS,im1.SUBCLASS) SUBCLASS
            FROM ZMS_ZPF_DIV_EXTRACT z,
                 pid_sku_master im,       -- WIN_SKUS w,
                 sub_items_head sih,   -- ZALE_REPL_SKU_GROUP_HEAD@over_to_rtkp zrsgh
                 pid_sku_master im1
            WHERE z.SKU = im.sku(+)
              AND z.repl_sku_group = sih.item(+) --zrsgh.repl_sku_group(+)
              AND z.store          = sih.location(+)
              AND z.repl_sku_group = im1.sku(+)) a,
      (SELECT DISTINCT SKU
         FROM zms_zpf_sku_override
        WHERE indicator = 'N') skuo,
      (SELECT DISTINCT division, dept, class, subclass
         FROM zms_zpf_dept_override
        WHERE class    IS NOT NULL
          AND subclass IS NOT NULL
          AND indicator = 'N') subclasso,
      (SELECT DISTINCT division, dept, class
         FROM zms_zpf_dept_override
        WHERE class    IS NOT NULL
          AND subclass IS NULL
          AND indicator = 'N') classo,
      (SELECT DISTINCT division, dept
         FROM zms_zpf_dept_override
        WHERE class    IS NULL
          AND subclass IS NULL
          AND indicator = 'N') depto
       WHERE a.request_sku = skuo.sku(+)
--       AND a.wh          = depto.wh(+)
         AND a.dept        = depto.dept(+)
         AND a.division    = depto.division(+)
--       AND a.wh          = classo.wh(+)
         AND a.dept        = classo.dept(+)
         AND a.class       = classo.class(+)
         AND a.division    = classo.division(+)
--       AND a.wh          = subclasso.wh(+)
         AND a.dept        = subclasso.dept(+)
         AND a.class       = subclasso.class(+)
         AND a.subclass    = subclasso.subclass(+)
         AND a.division    = subclasso.division(+))
     WHERE (subclass_override1 IS NOT NULL OR
            class_override1    IS NOT NULL OR
            dept_override1     IS NOT NULL OR
            sku_override1      IS NOT NULL);

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Insert  Sku/Dept/Class/SubClass Overrides END: '||SQL%ROWCOUNT));

      COMMIT;
      /***************************************************************/
      /* IF (the record is set to pick)                              */
      /***************************************************************/
      /*IF (l_pick) THEN
         /************************************************************/
         /* update the record based on the new watch indicator       */
         /************************************************************/
         /*IF (l_watch_indicator != l_skus.watch_priority) THEN
            --l_where := 'update for watch ind  '||TO_CHAR(l_skus.sku);
         */
      /*
            UPDATE ZMS_ZPF_DIV_EXTRACT
               SET watch_priority = l_watch_indicator
             WHERE STORE = l_skus.STORE
               AND SKU   = l_skus.SKU
               AND REQ   = l_skus.REQ
               AND repl_sku_group = l_skus.repl_sku_group;
      */
        -- END IF;
      /***************************************************************/
      /* Remove rows from zms_zpf_div_extract if row on              */
      /*    zms_zpf_div_override                                     */
      /***************************************************************/

      DELETE FROM ZMS_ZPF_DIV_EXTRACT
       WHERE (division, store, request_sku, req, repl_sku_group) IN
             (SELECT division, store, sku, req, repl_sku_group FROM zms_zpf_div_overrides);

      utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -    Remove  Sku/Dept/Class/SubClass Overrides END: '||SQL%ROWCOUNT));


/****************************************************************/
/* update zpf_nopick_report only for pick extracts. For forecast*/
/* No need to touch zpf_nopick_report table as per IR#1882      */
/****************************************************************/
       IF (NOT p_is_forecast) THEN

            UPDATE ZMS_ZPF_NOPICK_REPORT znr
               SET (pick_qty, reason_code) =
                   (SELECT pick_qty,
                           CASE WHEN sku_override1      IS NOT NULL THEN 'XSKU'
                                WHEN subclass_override1 IS NOT NULL THEN 'XSUBCLASS'
                                WHEN class_override1    IS NOT NULL THEN 'XCLASS'
                                WHEN dept_override1     IS NOT NULL THEN 'XDEPT'
                                ELSE 'XOTHER'
                           END reason_code
                      FROM zms_zpf_div_overrides zdo
                     WHERE zdo.division = znr.division
                       AND zdo.store = znr.store
                       AND zdo.sku   = znr.sku
                       AND zdo.req   = znr.req
                       AND zdo.repl_sku_group = znr.repl_sku_group)
                WHERE EXISTS
                   (SELECT 'x'
                      FROM zms_zpf_div_overrides zdo
                     WHERE zdo.division = znr.division
                       AND zdo.store = znr.store
                       AND zdo.sku   = znr.sku
                       AND zdo.req   = znr.req
                       AND zdo.repl_sku_group = znr.repl_sku_group);
        ELSE

           DELETE ZMS_ZPF_NOPICK_REPORT
            WHERE (division, store, sku, req, repl_sku_group) IN
                (SELECT division, store, sku, req, repl_sku_group FROM zms_zpf_div_overrides);

        END IF;
      /***************************************************************/
      /* end IF (the record is set to pick)                          */
      /***************************************************************/

   /******************************************************************/
   /* commit so we free up rollback segs                             */
   /******************************************************************/
   COMMIT;
   utl_file.put_line(g_log_fptr,'====================================================================');
   utl_file.fflush(g_log_fptr);
   utl_file.fclose(g_log_fptr);

EXCEPTION

   WHEN no_overrides THEN
        utl_file.put_line(g_log_fptr,('   No Overrides: '));
        utl_file.put_line(g_log_fptr,'====================================================================');
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        NULL;

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_process_overrides';
        O_err_code := 20105;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20105,SQLERRM);

END p_zpf_process_overrides;
/********************************************************************/
/*** PUBLIC PROCEDURE: p_zpf_upd_nopick_report                      */
/**** Author: Kishore Kumar                                         */
/********************************************************************/
PROCEDURE p_zpf_upd_nopick_report IS

CURSOR c_get_ord_qty IS
SELECT znr.ROWID c_rowid, zde.ord_qty c_ordqty
  FROM ZMS_ZPF_DIV_EXTRACT zde , ZMS_ZPF_NOPICK_REPORT znr
 WHERE zde.STORE = znr.STORE
   AND zde.SKU   = znr.SKU
   AND zde.REQ   = znr.REQ
   AND zde.repl_sku_group = znr.repl_sku_group;

CURSOR c_get_sku IS
SELECT zde.SKU c_sku ,
       znr.ROWID z_rowid
  FROM ZMS_ZPF_DIV_EXTRACT zde,
       ZMS_ZPF_NOPICK_REPORT znr
 WHERE zde.STORE = znr.STORE
   AND zde.REQ   = znr.REQ
   AND zde.repl_sku_group = znr.repl_sku_group
   AND znr.SKU   = -1;

l_sku    ZMS_ZPF_DIV_EXTRACT.SKU%TYPE;
l_ordqty ZMS_ZPF_NOPICK_REPORT.PICK_QTY%TYPE;
l_rowid  ROWID;
s_rowid  ROWID;
BEGIN
   /******************************************************************/
   /* Update the zpf_nopick_report table for sku groups. The value   */
   /* sku will be -1 for sku_groups. This will get sku from extract  */
   /* table zpf_div_extract. The sku for sku_groups in extract table */
   /* will be set in procedure p_alloc_sku_groups.                   */
   /******************************************************************/
    FOR my_sku IN c_get_sku
    LOOP
        l_sku   := my_sku.c_sku;
        s_rowid := my_sku.z_rowid;

        UPDATE ZMS_ZPF_NOPICK_REPORT znr
           SET znr.SKU = l_sku
         WHERE ROWID   = s_rowid;
    END LOOP;
    COMMIT;
    /******************************************************************/
    /* Get the pick_qty from zpf_div_extract i.e the qty available for*/
    /* Pick for given sku and store combination                       */
    /******************************************************************/
    FOR my_rec IN c_get_ord_qty
    LOOP
       l_ordqty := my_rec.c_ordqty;
       l_rowid  := my_rec.c_rowid;

       UPDATE ZMS_ZPF_NOPICK_REPORT
          SET pick_qty = l_ordqty
        WHERE ROWID  = l_rowid;
    END LOOP;
    COMMIT;
    /******************************************************************/
    /* Setting unit_cost and unit_retail for each sku requested for   */
    /* pick                                                           */
    /******************************************************************/
    UPDATE ZMS_ZPF_NOPICK_REPORT znr
       SET (unit_cost,unit_retail) =
           (SELECT ia.zms_estimated_landed_cost,ia.zms_unit_retail
            FROM item_attributes ia
     WHERE znr.SKU    = ia.item);
    COMMIT;
    /*************************************************************/
    /* Delete the repl_sku_group records from ZMS_ZPF_NOPICK_REPORT  */
    /* Which were excluded from pick                             */
    /*************************************************************/
    DELETE FROM ZMS_ZPF_NOPICK_REPORT
     WHERE repl_sku_group IN (
                         SELECT repl_sku_group
                           FROM ZMS_ZPF_NOPICK_REPORT znr
                          WHERE znr.SKU = -1
                            AND znr.reason_code IS NULL
                          MINUS
                         SELECT repl_sku_group
                           FROM ZMS_ZPF_DIV_EXTRACT);
    COMMIT;

EXCEPTION

    WHEN OTHERS THEN
         RAISE_APPLICATION_ERROR (-20103,SQLERRM);

END p_zpf_upd_nopick_report;
/*********************************************************************/
/* PUBLIC PROCEDURE: p_zpf_reduce_to_max_pick                        */
/* DESCRIPTION: The requests for items has exceeded the maximum      */
/*    amount that can be picked.  We need to reduce the pick to the  */
/*    maximum amount.  In order of priority, we will keep:           */
/*    1. priority based on dist type                                 */
/*    2. stores with 0 stock on hand                                 */
/*    3. stores with the greatest demand                             */
/*    4. stores with least stock on hand                             */
/*    5. repl_store_group                                            */
/*    6. requisition number(to try and evenly distribute among       */
/*       stores)                                                     */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/* ================================================================= */
/* 1177| added priority based on dist type and repl_store_group      */
/*     | to order by clause.  LCB 6 February, 1997                   */
/* ================================================================= */
/* unkn|Unnumbered IR from the DBAs to improve performance.  Removed */
/*     | sort by store group added above.  The priority is now:      */
/*     | 1. distribution type priority based on zale_dist_type table */
/*     | 2. out of stock                                             */
/*     | 3. highest demand                                           */
/*     | 4. least stock                                              */
/*     | 5. requisition (to try and evenly distribute to stores)     */
/*     | LCB 12 March, 1997                                          */
/* ================================================================= */
/* ????|added division priority to the order by clause               */
/*********************************************************************/
PROCEDURE p_zpf_reduce_to_max_pick (pm_max_pick IN NUMBER,
                                pm_wh       IN NUMBER) IS
   l_current_pick   item_loc_soh.stock_on_hand%TYPE;
   l_req            alloc_header.alloc_no%TYPE;
--sa   l_req            REQ.REQ%TYPE;
   l_sku            item_master.item%TYPE;
   l_store          STORE.STORE%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_pick_qty       ZMS_ZPF_NOPICK_REPORT.pick_qty%TYPE;
   l_nopick_rowid   ROWID;
   l_ord_qty        NUMBER;
   /******************************************************************/
   /* this cursor helps me decide who gets stock when the requests   */
   /* exceed the maximum that the DC can pick.  First priority is    */
   /* those stores that are out of stock.  We get this by the decode */
   /* statement that returns an 'A' if the store is out of stock and */
   /* a 'B' if the store has any stock.  Second priority is those    */
   /* with the greatest differential between need and on_hand.  This */
   /* is captured by the second part of the order by clause 'z.ord_  */
   /* qty DESC.'  The third priority is stock on hand ascending.     */
   /* This is captured by the third part of the order by clause      */
   /* 'z.stock_on_hand.' Past that, we sort by request then store in */
   /* order to hopefully evenly distribute among stores.             */
   /******************************************************************/
   CURSOR c_req_records IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
--sa       REQDETAIL@over_to_rtkp r,
        ZMS_ZPF_DCS_DIV zdd
--sa   WHERE z.REQ      = r.REQ
--sa     AND (r.SKU     = z.SKU OR r.SKU = -1)
--sa     AND z.repl_sku_group = r.repl_sku_group
--sa     AND z.STORE    = r.STORE
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       = pm_wh
   ORDER BY zdd.priority,             /* divisional priority */
         z.priority,                  /* type of request     */
         out_of_stock,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ,
         z.store;

   CURSOR c_req_records_8591 IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
--sa        REQDETAIL@over_to_rtkp r,
        ZMS_ZPF_DCS_DIV zdd
--sa   WHERE z.REQ      = r.REQ
--sa     AND (r.SKU     = z.SKU OR r.SKU = -1)
--sa     AND z.repl_sku_group = r.repl_sku_group
--sa     AND z.STORE    = r.STORE
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       IN (8904, 8591)
   ORDER BY zdd.priority,             /* divisional priority */
         z.priority,                  /* type of request     */
         out_of_stock,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ,
         z.store;
BEGIN
   l_current_pick := 0;
   /******************************************************************/
   /* loop through all request records                               */
   /******************************************************************/
   IF pm_wh = 8904 THEN
    FOR l_req_records IN c_req_records_8591
    LOOP
     p_zpf_reduce_to_max_by_wh(pm_max_pick,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
    utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - curr pick '||l_current_pick||', max '||pm_max_pick));
    END LOOP;
   ELSE
    FOR l_req_records IN c_req_records
    LOOP
      /***************************************************************/
      /* IF (we have already met the maximum pick) then delete the   */
      /*    record                                                   */
      /***************************************************************/
     p_zpf_reduce_to_max_by_wh(pm_max_pick,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
    END LOOP;
   END IF;
END p_zpf_reduce_to_max_pick;
----------------------------------------------------------------------
/***************************************************************/
PROCEDURE p_zpf_reduce_to_max_by_wh (pm_max_pick IN NUMBER,
                                 pm_req      IN NUMBER,
                                 pm_sku      IN NUMBER,
                                 pm_store    IN NUMBER,
                                 pm_repl_sku_group IN NUMBER,
                                 pm_ord_qty  IN NUMBER,
                                 pm_current_pick IN OUT NUMBER) IS
--   l_current_pick   item_loc_soh.stock_on_hand%TYPE ;
   l_req            alloc_header.alloc_no%TYPE;
--sa   l_req            REQ.REQ%TYPE;
   l_sku            item_master.item%TYPE;
   l_store          STORE.STORE%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_pick_qty       ZMS_ZPF_NOPICK_REPORT.pick_qty%TYPE;
   l_nopick_rowid   ROWID;
   l_ord_qty        NUMBER;
   l_max_pick       NUMBER;


   CURSOR c_zpf_nopick_report IS
   SELECT pick_qty, ROWID
     FROM ZMS_ZPF_NOPICK_REPORT
    WHERE REQ   = pm_req
      AND STORE = pm_store
      AND SKU   = pm_sku
      AND repl_sku_group = pm_repl_sku_group;
BEGIN
      l_max_pick := pm_max_pick ;
      l_req      := pm_req;
      l_sku      := pm_sku;
      l_store    := pm_store;
      l_repl_sku_group := pm_repl_sku_group;
      l_ord_qty  := pm_ord_qty;
--      l_current_pick   := pm_current_pick;
      /***************************************************************/
      /* IF (we have already met the maximum pick) then delete the   */
      /*    record                                                   */
      /***************************************************************/
      IF (pm_current_pick = pm_max_pick) THEN
         IF (pm_repl_sku_group = -1) THEN
            UPDATE ZMS_ZPF_NOPICK_REPORT
               SET pick_qty = 0,
                   reason_code = 'XMAX'
             WHERE REQ   = pm_REQ
               AND STORE = pm_STORE
               AND SKU   = pm_sku
               AND repl_sku_group = pm_repl_sku_group;
         ELSE
            l_req := pm_REQ;
            l_sku := pm_sku;
            l_store := pm_STORE;
            l_repl_sku_group := pm_repl_sku_group;
            --l_pick_qty := pm_pick_qty;

            OPEN c_zpf_nopick_report;
            FETCH c_zpf_nopick_report
            INTO l_pick_qty, l_nopick_rowid;
            IF c_zpf_nopick_report%FOUND THEN
              l_pick_qty := l_pick_qty - pm_ord_qty;

              UPDATE ZMS_ZPF_NOPICK_REPORT
                 SET pick_qty = l_pick_qty
               WHERE ROWID = l_nopick_rowid;
            END IF;
            CLOSE c_zpf_nopick_report;
         END IF;

         DELETE FROM ZMS_ZPF_DIV_EXTRACT
          WHERE STORE = l_STORE
            AND SKU   = l_sku
            AND REQ   = l_REQ
            AND repl_sku_group = l_repl_sku_group;
      /***************************************************************/
      /* else IF (the request quantity is bigger than the amount     */
      /*    left in the maximum pick) then reduce the request        */
      /*    quantity to the amount left                              */
      /***************************************************************/
      ELSIF (l_ord_qty >(pm_max_pick - pm_current_pick)) THEN
         IF (l_repl_sku_group = -1) THEN
            UPDATE ZMS_ZPF_NOPICK_REPORT
               SET pick_qty = 0,
                   reason_code = 'XMAX'
             WHERE REQ   = pm_REQ
               AND STORE = pm_STORE
               AND SKU   = pm_sku
               AND repl_sku_group = pm_repl_sku_group;
         ELSE
            l_req := pm_REQ;
            l_sku := pm_sku;
            l_store := pm_STORE;
            l_repl_sku_group := pm_repl_sku_group;

            OPEN c_zpf_nopick_report;
            FETCH c_zpf_nopick_report
             INTO l_pick_qty, l_nopick_rowid;

            IF c_zpf_nopick_report%FOUND THEN
              l_pick_qty := l_pick_qty - (pm_max_pick - pm_current_pick);
              UPDATE ZMS_ZPF_NOPICK_REPORT
                 SET pick_qty = l_pick_qty
               WHERE ROWID = l_nopick_rowid;
            END IF;
            CLOSE c_zpf_nopick_report;
         END IF;

         UPDATE ZMS_ZPF_DIV_EXTRACT
            SET ord_qty = pm_max_pick - pm_current_pick,
                stock_avail = -9999999
            WHERE REQ   = l_REQ
            AND STORE   = l_STORE
            AND SKU     = l_sku
            AND repl_sku_group = l_repl_sku_group;

         pm_current_pick := pm_max_pick;
      /***************************************************************/
      /* else(there is more left in the current pick than the       */
      /*    current request) so add the amount of the current request*/
      /*    to the current amount picked                             */
      /***************************************************************/
      ELSE
         pm_current_pick := pm_current_pick + pm_ord_qty;
      /***************************************************************/
      /* end IF (we have already met the maximum pick)               */
      /***************************************************************/
      END IF;

EXCEPTION

    WHEN OTHERS THEN
         RAISE_APPLICATION_ERROR (-20104,SQLERRM);

END p_zpf_reduce_to_max_by_wh;
/*********************************************************************/
/* PUBLIC FUNCTION: P_EXCEEDED_MAX_PICK                              */
/* DESCRIPTION: Retrieves the maximum amount the distribution center */
/*    can pick and the total amount requested.  If the total amount  */
/*    requested exceeds the maximum amount that can be picked, we    */
/*    return TRUE.                                                   */
/* RETURNS: TRUE - exceeded maximum amount that can be picked in a   */
/*          day.                                                     */
/*       FALSE - within the maximum amount that can be picked.       */
/*    pm_max_pick - the number of items that can be picked in a day  */
/*                                                                   */
/* AUTHOR: Loyal C. Barber, MCI Systemhouse                          */
/* MODIFICATIONS:                                                    */
/* ================================================================= */
/*  IR | Description                                                 */
/*  XX | Changed from function to PROCEDURE to be called from proC   */
/* ================================================================= */
/*********************************************************************/

PROCEDURE P_ZPF_EXCEEDED_MAX_PICK IS
   l_req_qty        NUMBER;
   l_max_pick_qty   NUMBER ;
   l_boolean        BOOLEAN;
   l_wh             item_loc_soh.loc%TYPE;
   l_current_pick   item_loc_soh.stock_on_hand%TYPE;
   l_req            alloc_header.alloc_no%TYPE;
--sa   l_req            REQ.REQ%TYPE;
   l_sku            item_master.item%TYPE;
   l_store          STORE.STORE%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_pick_qty       ZMS_ZPF_NOPICK_REPORT.pick_qty%TYPE;
   l_nopick_rowid   ROWID;
   l_ord_qty        NUMBER;
   /******************************************************************/
   /* retrieves the maximum quantity of items that can be picked in  */
   /* a given pick                                                   */
   /******************************************************************/
   CURSOR c_get_pick_limit IS
   SELECT flex_num2 quantity, flex_num WH
     FROM ZMS_STORE_FLEX_VALUES
    WHERE flex_type = 'max_qty_pick';
   /******************************************************************/
   /* retrieves the quantity requested from the ZMS_ZPF_DIV_EXTRACT      */
   /* table                                                          */
   /******************************************************************/
   CURSOR c_get_qty_req IS
   SELECT SUM(ord_qty)
     FROM ZMS_ZPF_DIV_EXTRACT;


   /******************************************************************/
   /* this cursor helps me decide who gets stock when the requests   */
   /* exceed the maximum that the DC can pick.  First priority is    */
   /* those stores that are out of stock.  We get this by the decode */
   /* statement that returns an 'A' if the store is out of stock and */
   /* a 'B' if the store has any stock.  Second priority is those    */
   /* with the greatest differential between need and on_hand.  This */
   /* is captured by the second part of the order by clause 'z.ord_  */
   /* qty DESC.'  The third priority is stock on hand ascending.     */
   /* This is captured by the third part of the order by clause      */
   /* 'z.stock_on_hand.' Past that, we sort by request then store in */
   /* order to hopefully evenly distribute among stores.             */
   /******************************************************************/
   CURSOR c_req_records IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
--sa        REQDETAIL@over_to_rtkp r,
        ZMS_ZPF_DCS_DIV zdd
--sa   WHERE z.REQ      = r.REQ
--sa     AND (r.SKU     = z.SKU OR r.SKU = -1)
--sa     AND z.repl_sku_group = r.repl_sku_group
--sa     AND z.STORE    = r.STORE
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       = l_wh
   ORDER BY zdd.priority,             /* divisional priority */
         z.priority,                  /* type of request     */
         out_of_stock,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ,
         z.store;

   CURSOR c_req_records_8591 IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
--sa        REQDETAIL@over_to_rtkp r,
        ZMS_ZPF_DCS_DIV zdd
--sa   WHERE z.REQ      = r.REQ
--sa     AND (r.SKU     = z.SKU OR r.SKU = -1)
--sa     AND z.repl_sku_group = r.repl_sku_group
--sa     AND z.STORE    = r.STORE
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       IN (8904, 8591)
   ORDER BY zdd.priority,             /* divisional priority */
         z.priority,                  /* type of request     */
         out_of_stock,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ,
         z.store;
BEGIN

g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');

   FOR limit_rec IN c_get_pick_limit
   LOOP
     l_wh := limit_rec.WH;
     l_max_pick_qty := limit_rec.quantity;
     IF l_wh = 8904 THEN
        SELECT SUM(ord_qty)
          INTO l_req_qty
          FROM ZMS_ZPF_DIV_EXTRACT
         WHERE WH IN (8904, 8591);
     ELSE
        SELECT SUM(ord_qty)
          INTO l_req_qty
          FROM ZMS_ZPF_DIV_EXTRACT
         WHERE WH = l_wh;
     END IF;
     IF (l_max_pick_qty < NVL(l_req_qty,0)) THEN
       -- P_ZPF_REDUCE_TO_MAX_PICK(l_max_pick_qty, l_wh);

      l_current_pick := 0;
   /******************************************************************/
   /* loop through all request records                               */
   /******************************************************************/
      IF l_wh = 8904 THEN
       FOR l_req_records IN c_req_records_8591
       LOOP
        p_zpf_reduce_to_max_by_wh(l_max_pick_qty,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
     --utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - curr pick '||l_current_pick||', max '||pm_max_pick));
       END LOOP;
      ELSE
       FOR l_req_records IN c_req_records
       LOOP
      /***************************************************************/
      /* IF (we have already met the maximum pick) then delete the   */
      /*    record                                                   */
      /***************************************************************/
        p_zpf_reduce_to_max_by_wh(l_max_pick_qty,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
       END LOOP;
      END IF;
     ELSE
        NULL;   /*Do Nothing*/
     END IF;
    END LOOP;

    utl_file.put_line(g_log_fptr,'====================================================================');
    utl_file.fflush(g_log_fptr);
    utl_file.fclose(g_log_fptr);

END P_ZPF_EXCEEDED_MAX_PICK;

/**************************************************************************/
/**************************************************************************/
/* PUBLIC PROCEDURE : p_zpf_alloc_sku_groups
   Function         : Warehouse Process Control for p_zpf_alloc_sku_groups
/**************************************************************************/
PROCEDURE p_zpf_alloc_sku_groups (p_is_forecast IN BOOLEAN,
                                  O_err_code   OUT INTEGER) IS
   l_req               ALLOC_HEADER.ALLOC_NO%TYPE;
--   l_req               REQDETAIL.REQ%TYPE;
   l_req               ZMS_ZPF_DIV_EXTRACT.REQ%TYPE;
   l_sku               ZMS_ZPF_DIV_EXTRACT.SKU%TYPE;
   l_division          ZMS_ZPF_DIV_EXTRACT.DIVISION%TYPE;
   l_wh                WH.WH%TYPE;
   l_nopick_sku        ZMS_ZPF_NOPICK_REPORT.SKU%TYPE;
   l_nopick_retail     ZMS_ZPF_NOPICK_REPORT.UNIT_RETAIL%TYPE;
   l_nopick_cost       ZMS_ZPF_NOPICK_REPORT.UNIT_COST%TYPE;
   l_stock_avail       ZMS_ZPF_WIN_WH.STOCK_AVAIL%TYPE;
   l_repl_orig_wh      WH.WH%TYPE;
   l_repl_sku_group    ZMS_ZPF_DIV_EXTRACT.REPL_SKU_GROUP%TYPE;
   l_ord_qty           ZMS_ZPF_DIV_EXTRACT.ORD_QTY%TYPE;
   l_repl_sku          SUB_ITEMS_HEAD.ITEM%TYPE;
--sa   l_repl_sku          ZALE_REPL_SKU_GROUP_DETAIL.SKU%TYPE;
   l_lp_num            NUMBER := 0; /* Represents the priority */
   l_new_qty           NUMBER;
   l_close_loop        NUMBER;
   l_count             NUMBER := 0;
   l_no_repl_sku_group NUMBER := -1;
-- l_zpf_req           ZMS_ZALE_FEEDBACK.REQ%TYPE;
-- l_zf_req            ZMS_ZALE_FEEDBACK.REQ%TYPE;
-- l_zf_sku            ZMS_ZALE_FEEDBACK.SKU%TYPE;
-- l_zf_store          ZMS_ZALE_FEEDBACK.STORE%TYPE;
-- l_zf_repl_sku_group ZMS_ZALE_FEEDBACK.REPL_SKU_GROUP%TYPE;
   l_current_pick_qty  ZMS_ZPF_NOPICK_REPORT.PICK_QTY%TYPE;
   l_store             ZMS_ZPF_DIV_EXTRACT.STORE%TYPE;
   o_max_pick_qty      item_loc_soh.stock_on_hand%TYPE;
   i_max_pick_qty      item_loc_soh.stock_on_hand%TYPE;
   l_exceeded          NUMBER := 0;
   fptr                utl_file.file_type;
   char_sg             VARCHAR2(10);
   O_error_message     VARCHAR2(2000);
   no_sku_groups       EXCEPTION;
/*The following cursoris used to determine the total order qty
for each replenishment sku group */
      CURSOR c_get_repl_sku_group IS
      SELECT wc.process_no, zpf.orig_wh, zpf.repl_sku_group, SUM(NVL(zpf.ord_qty,0)) req_qty
        FROM zms_zpf_div_extract zpf, zms_zpf_wh_control wc
       WHERE zpf.sku     = -1
         AND zpf.orig_wh = wc.orig_wh
         AND zpf.orig_wh = wc.pick_wh
       GROUP BY wc.process_no, zpf.orig_wh, zpf.repl_sku_group
       ORDER BY wc.process_no, zpf.orig_wh, zpf.repl_sku_group;

/*The following cursor is used to determine the total stock at sku level
    for each replenishment sku group */

     CURSOR c_get_stock_matrix IS
     SELECT wwz.sku,
            wwz.stock_avail stock,
            zwc.pick_wh wh,
            NVL(isc.inner_pack_size,1) inner_pack_size
      FROM ZMS_ZPF_WIN_WH wwz, ITEM_SUPP_COUNTRY isc,
           zms_zpf_wh_control zwc, zms_zpf_main_sub zms
--sa      ZALE_REPL_SKU_GROUP_DETAIL@over_to_rtkp zrsgd
      WHERE zwc.orig_wh = l_repl_orig_wh --IN (8904,8591) -- 8450
        AND zwc.pick_wh = wwz.WH
        AND wwz.sku     = zms.sub_item
        AND zms.item    = l_repl_sku_group
        AND zms.item    = isc.item
        AND isc.primary_supp_ind    = 'Y'
        AND isc.primary_country_ind = 'Y'
        AND zwc.active_flag         = 'Y'
        AND NVL(wwz.stock_avail,0) >= NVL(isc.inner_pack_size,1) --0
        AND zwc.pick_wh IN (SELECT wh FROM zms_zpf_pick_day_stores)
      ORDER BY zwc.process_no, zms.item_pick_priority;

     /* CURSOR c_get_stock_matrix IS
      SELECT wwz.SKU,
             wwz.stock_avail stock
             ,wwz.WH                                           -- J.P. 082006
        FROM WIN_WH_ZPF wwz,
             ZALE_REPL_SKU_GROUP_DETAIL gd,
             ZALE_REPL_SKU_GROUP_INFO gi
       WHERE gi.WH = wwz.WH                              -- J.P.
         AND gi.REPL_SKU_GROUP = gd.REPL_SKU_GROUP    -- J.P.
       --WH IN (SELECT WH FROM WH WHERE wh_type_no = 0)  --WH = 8904
         AND wwz.SKU = gd.SKU
         AND gd.repl_sku_group = l_repl_sku_group
         AND NVL(wwz.stock_avail,0) > 0
       ORDER BY  gd.repl_priority; */

   CURSOR c_get_zpf_div_extract_repl IS
   SELECT /*+ index (R REQDETAIL_I2) */
          z.REQ,
          z.SKU,
          z.ord_qty,
          z.repl_sku_group,
          z.STORE,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.stock_on_hand,
          z.po_line_nbr,
          z.po_type,
          z.DIVISION,
          z.store_priority,
          z.in_str_date,
          z.distro_date,
          z.cust_name,
          z.priority,
          z.watch_priority,
          z.ROWID myrow,NVL(zdt.fill_to_model,'N') ftm,
          zdt.dist_type,
          z.WH,
          z.orig_wh,
          z.orig_req,
          z.orig_po_type,
          z.orig_ord_qty,
          z.pick_process_nbr
   FROM ZMS_ZPF_DIV_EXTRACT z,
--sa        REQDETAIL@over_to_rtkp r,
--sa        STORE s,
--sa        DISTRICT d,
        (SELECT DISTINCT item FROM SUB_ITEMS_HEAD) sih,
--sa   ZALE_REPL_SKU_GROUP_HEAD@over_to_rtkp zrsgh,
        ZMS_ZALE_DIST_TYPE zdt
--sa   WHERE z.REQ   = r.REQ
--sa     AND z.SKU   = r.SKU
--sa     AND z.repl_sku_group = r.repl_sku_group
--sa     AND z.STORE = r.STORE
   WHERE z.SKU   = -1
--sa     AND z.STORE = s.STORE
--sa     AND s.DISTRICT       = d.DISTRICT
     AND z.repl_sku_group = sih.item
--     AND z.STORE          = sih.location
     AND z.repl_sku_group = l_repl_sku_group
     AND z.orig_wh        = l_repl_orig_wh
     AND z.DIVISION       = zdt.DIVISION
     AND z.dist_type      = zdt.dist_type
   ORDER BY z.priority,
         out_of_stock,
         z.store_priority,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ;

      TYPE st_ord_qty IS TABLE OF
      ZMS_ZPF_DIV_EXTRACT.ORD_QTY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_store IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.STORE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_req IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.REQ%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_po_line_nbr IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.PO_LINE_NBR%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_po_type IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.PO_TYPE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_in_str_date IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.IN_STR_DATE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_distro_date IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.DISTRO_DATE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_cust_name IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.CUST_NAME%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_priority IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.PRIORITY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_store_priority IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.STORE_PRIORITY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_division IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.DIVISION%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_wh IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.WH%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_watch_priority IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.WATCH_PRIORITY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_fill_to_model IS TABLE OF
        ZMS_ZALE_DIST_TYPE.FILL_TO_MODEL%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_sku IS TABLE
       OF NUMBER
       INDEX BY BINARY_INTEGER;
/*******Declaring The Counters *****/
   l_stk_cnt        BINARY_INTEGER := 0;
   l_stk_start      BINARY_INTEGER := 0;
   l_stk_end        BINARY_INTEGER := 0;
   l_rs_counter     BINARY_INTEGER := 0;
   l_repl_cnt       BINARY_INTEGER := 0;
   i                BINARY_INTEGER := 0;
   l_repl_start_cnt BINARY_INTEGER := 0;
   l_repl_end_cnt   BINARY_INTEGER := 0;
   l_repl_current_cnt BINARY_INTEGER := 0;
   l_repl_insert_cnt  BINARY_INTEGER := 0;
   v_pack_size        BINARY_INTEGER := 0;

/*******End of Declaring The Counters *****/
/**********Declaring Actual Variables of Type Table **********************/
   mt_sku            st_sku;
   mt_sku1           st_sku;
   mt_repl_sku_group st_sku;
   mt_repl_skgp      st_sku;
   mt_repl_skgp1     st_sku;
   mt_req_qty        st_sku;
   mt_stock_avail    st_sku;
   mt_stock_avail_sku st_sku;
   mt_ord_qty        st_ord_qty;
   mt_distro_qty     st_ord_qty;
   mt_stock_on_hand  st_ord_qty;
   mt_store          st_store;
   mt_req            st_req;
   mt_po_line_nbr    st_po_line_nbr;
   mt_po_type        st_po_type;
   mt_dist_type      st_po_type;
   mt_in_str_date    st_in_str_date;
   mt_distro_date    st_distro_date;
   mt_cust_name      st_cust_name;
   mt_priority       st_priority;
   mt_store_priority st_store_priority;
   mt_division       st_division;
   mt_wh             st_wh;
   mt_wh1            st_wh;
   mt_watch_priority st_watch_priority;
   mt_fill_to_model  st_fill_to_model;
   mt_check_full     st_fill_to_model;
   mt_pack_size      st_sku;
   mt_orig_wh        st_wh;
   mt_orig_req       st_req;
   mt_orig_po_type   st_po_type;
   mt_orig_ord_qty   st_ord_qty;
   mt_pick_process_nbr st_ord_qty;
/**********End of Declaring Actual Variables of Type Table ***********/
   l_tot_stock    NUMBER := 0;
   l_to_be_filled NUMBER := 0;
BEGIN

g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
fptr := utl_file.fopen(g_log_fdir,'zms_zl_pick_sku_groups.log','W');

utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_zpf_alloc_sku_groups started:'));

      SELECT COUNT(*) INTO l_count
        FROM ZMS_ZPF_DIV_EXTRACT
       WHERE SKU = -1;

--   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -     l_count: '||l_count||' '));

   IF l_count = 0 THEN
      utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -     No SKU Groups'));
      RAISE no_sku_groups;
   END IF;

-- fptr := utl_file.fopen('ZSEND','zms_zpf_pick_scarce_sg','w');
   FOR l_repl_sku_group1 IN c_get_repl_sku_group
   LOOP
       l_repl_orig_wh   := l_repl_sku_group1.orig_wh;
       l_repl_sku_group := l_repl_sku_group1.repl_sku_group;
       utl_file.put_line(g_log_fptr, '1 - l_repl_orig_wh - '|| l_repl_orig_wh ||'  l_repl_sku_group - ' || NVL(l_repl_sku_group,-2));
       utl_file.fflush(g_log_fptr);
    char_sg := TO_CHAR(l_repl_sku_group);
    utl_file.putf(fptr,'Processing Sku GROUP %s\n',char_sg);
    utl_file.fflush(fptr);
       l_rs_counter := l_rs_counter + 1;
    l_tot_stock := 0;

    FOR l_get_stock_matrix IN c_get_stock_matrix
    LOOP
      l_stk_cnt := l_stk_cnt+1;
      IF (l_stk_start = 0) THEN
         l_stk_start := l_stk_cnt;
      END IF;
      mt_sku(l_stk_cnt) := l_get_stock_matrix.SKU;
      mt_wh(l_stk_cnt)  := l_get_stock_matrix.WH;    --J.P. 082006
      mt_stock_avail_sku(l_stk_cnt):= l_get_stock_matrix.stock;

      --utl_file.put_line(g_log_fptr, '2 - l_repl_orig_wh - '|| l_repl_orig_wh ||'  l_repl_sku_group - ' || NVL(l_repl_sku_group,-2) || '  mt_sku(l_stk_cnt) - ' || NVL(mt_sku(l_stk_cnt),-2) || '  mt_wh(l_stk_cnt) - ' || NVL(mt_wh(l_stk_cnt),-2));
      --utl_file.fflush(g_log_fptr);

      l_tot_stock := l_tot_stock + mt_stock_avail_sku(l_stk_cnt);
      mt_pack_size (l_stk_cnt) := l_get_stock_matrix.inner_pack_size;
      v_pack_size := mt_pack_size (l_stk_cnt);
    END LOOP; /*Stock Matrix....*/
    l_stk_end := l_stk_cnt;
    mt_repl_skgp(l_rs_counter) := l_repl_sku_group;
    mt_stock_avail(l_rs_counter) := l_tot_stock;
    mt_req_qty(l_rs_counter) := l_repl_sku_group1.req_qty;
    l_repl_cnt := 0;
    --utl_file.put_line(g_log_fptr, '3 - l_repl_orig_wh - '|| l_repl_orig_wh ||'  l_repl_sku_group - ' || NVL(l_repl_sku_group,-2) || '  mt_sku(l_stk_cnt) - ' || NVL(mt_sku(l_stk_cnt),-2) || '  mt_wh(l_stk_cnt) - ' || NVL(mt_wh(l_stk_cnt),-2));
    --utl_file.fflush(g_log_fptr);
    FOR l_get_zpf_div_extract_repl IN c_get_zpf_div_extract_repl
    LOOP

     --utl_file.put_line(g_log_fptr, '4');
     --utl_file.fflush(g_log_fptr);

     l_repl_cnt := l_repl_cnt +1;
     IF l_repl_start_cnt = 0 THEN
     l_repl_start_cnt := l_repl_cnt;
     END IF;

     mt_req(l_repl_cnt)         := l_get_zpf_div_extract_repl.REQ;
     mt_sku1(l_repl_cnt)        := l_get_zpf_div_extract_repl.SKU;
     mt_ord_qty(l_repl_cnt)     := l_get_zpf_div_extract_repl.ord_qty;
     mt_distro_qty(l_repl_cnt)  := 0;
     mt_repl_skgp1(l_repl_cnt)  := l_get_zpf_div_extract_repl.repl_sku_group;
     mt_store(l_repl_cnt)       := l_get_zpf_div_extract_repl.STORE;
     mt_po_line_nbr(l_repl_cnt) := l_get_zpf_div_extract_repl.po_line_nbr;
     mt_po_type(l_repl_cnt)     := l_get_zpf_div_extract_repl.po_type;
     mt_stock_on_hand(l_repl_cnt) := l_get_zpf_div_extract_repl.stock_on_hand;
     mt_dist_type(l_repl_cnt)   := l_get_zpf_div_extract_repl.dist_type;
     mt_division(l_repl_cnt)    := l_get_zpf_div_extract_repl.DIVISION;
     mt_wh1(l_repl_cnt)         := l_get_zpf_div_extract_repl.WH;
     mt_store_priority(l_repl_cnt)    := l_get_zpf_div_extract_repl.store_priority;
     mt_in_str_date(l_repl_cnt) := l_get_zpf_div_extract_repl.in_str_date;
     mt_distro_date(l_repl_cnt) := l_get_zpf_div_extract_repl.distro_date;
     mt_cust_name(l_repl_cnt)   := l_get_zpf_div_extract_repl.cust_name;
     mt_priority(l_repl_cnt)    := l_get_zpf_div_extract_repl.priority;
     mt_watch_priority(l_repl_cnt) := l_get_zpf_div_extract_repl.watch_priority;
     mt_fill_to_model(l_repl_cnt)  := l_get_zpf_div_extract_repl.ftm;
     mt_orig_wh(l_repl_cnt)        := l_get_zpf_div_extract_repl.orig_wh;
     mt_orig_req(l_repl_cnt)       := l_get_zpf_div_extract_repl.orig_req;
     mt_orig_po_type(l_repl_cnt)   := l_get_zpf_div_extract_repl.orig_po_type;
     mt_orig_ord_qty(l_repl_cnt)   := l_get_zpf_div_extract_repl.orig_ord_qty;
     mt_pick_process_nbr(l_repl_cnt) := l_repl_cnt;
     mt_check_full(l_repl_cnt)     := 'X';
    END LOOP; /* Repl Detail...*/
    l_repl_end_cnt := l_repl_cnt;
    i := l_stk_start;
    l_repl_current_cnt := l_repl_start_cnt;
    --utl_file.put_line(g_log_fptr, '5 mt_req_qty(l_rs_counter) - '||mt_req_qty(l_rs_counter) ||'  mt_stock_avail(l_rs_counter) - '||mt_stock_avail(l_rs_counter));
    --utl_file.fflush(g_log_fptr);

    IF mt_req_qty(l_rs_counter) <= mt_stock_avail(l_rs_counter) THEN
    --utl_file.put_line(g_log_fptr, '6');
    --utl_file.fflush(g_log_fptr);

    LOOP
      EXIT WHEN mt_req_qty(l_rs_counter) = 0;
    --utl_file.put_line(g_log_fptr, '7');
    --utl_file.fflush(g_log_fptr);

      IF mt_check_full(l_repl_current_cnt) = 'X' THEN
       IF mt_stock_avail_sku(I) >= mt_ord_qty(l_repl_current_cnt) THEN
         mt_sku1(l_repl_current_cnt) := mt_sku(I);
         mt_wh1(l_repl_current_cnt)  := mt_wh(I);
         mt_stock_avail_sku(I) := mt_stock_avail_sku(I) -
                     mt_ord_qty(l_repl_current_cnt);
         IF mt_stock_avail_sku(I) = 0
            OR mt_stock_avail_sku (i) < v_pack_size
         THEN
            i := I+1;
         END IF;
         mt_req_qty(l_rs_counter) := mt_req_qty(l_rs_counter) -
                 mt_ord_qty(l_repl_current_cnt);
         mt_distro_qty(l_repl_current_cnt) := mt_ord_qty(l_repl_current_cnt);
         mt_check_full(l_repl_current_cnt) := 'Y';
         IF l_repl_current_cnt < l_repl_end_cnt THEN
           l_repl_current_cnt := l_repl_current_cnt + 1;
         ELSE
           l_repl_current_cnt := 1;

         END IF;
        ELSE
         l_repl_insert_cnt        := l_repl_insert_cnt + 1;
         mt_sku1(l_repl_end_cnt + l_repl_insert_cnt)     := mt_sku(I);
         mt_ord_qty(l_repl_end_cnt+l_repl_insert_cnt)    := mt_stock_avail_sku(I);
         mt_distro_qty(l_repl_end_cnt+l_repl_insert_cnt) :=
                                                         mt_stock_avail_sku(I);
         mt_req_qty(l_rs_counter)                        := mt_req_qty(l_rs_counter) -
                                                         mt_stock_avail_sku(I);
         mt_req(l_repl_end_cnt + l_repl_insert_cnt)      :=
                                                         mt_req(l_repl_current_cnt);
            mt_ord_qty(l_repl_end_cnt + l_repl_insert_cnt)  :=
                                                         mt_stock_avail_sku(I) ;
            mt_ord_qty(l_repl_current_cnt)                  := mt_ord_qty(l_repl_current_cnt) -
                                                         mt_stock_avail_sku(I) ;
            mt_repl_skgp1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                         mt_repl_skgp1(l_repl_current_cnt);
            mt_store(l_repl_end_cnt + l_repl_insert_cnt)    :=
                                                            mt_store(l_repl_current_cnt);
            mt_po_line_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_po_line_nbr(l_repl_current_cnt);
            mt_po_type(l_repl_end_cnt + l_repl_insert_cnt)  :=
                                                            mt_po_type(l_repl_current_cnt);
            mt_stock_on_hand(l_repl_end_cnt + l_repl_insert_cnt)  :=
                                                            mt_stock_on_hand(l_repl_current_cnt);
            mt_dist_type(l_repl_end_cnt + l_repl_insert_cnt):=
                                                            mt_dist_type(l_repl_current_cnt);
            mt_division(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_division(l_repl_current_cnt);
         mt_wh1(l_repl_end_cnt + l_repl_insert_cnt) :=    mt_wh(I);
         mt_store_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_store_priority(l_repl_current_cnt);
            mt_in_str_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_in_str_date(l_repl_current_cnt);
            mt_distro_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_distro_date(l_repl_current_cnt);
            mt_cust_name(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_cust_name(l_repl_current_cnt);
            mt_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_priority(l_repl_current_cnt);
            mt_watch_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_watch_priority(l_repl_current_cnt);
            mt_fill_to_model(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_fill_to_model(l_repl_current_cnt);
            mt_orig_wh(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_orig_wh(l_repl_current_cnt);
            mt_orig_req(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_orig_req(l_repl_current_cnt);
            mt_orig_po_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_orig_po_type(l_repl_current_cnt);
            mt_orig_ord_qty(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_orig_ord_qty(l_repl_current_cnt);
            mt_pick_process_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                            mt_pick_process_nbr(l_repl_current_cnt);
            mt_stock_avail_sku(I)                           := 0;
         mt_check_full(l_repl_end_cnt+l_repl_insert_cnt) := 'Y';
         mt_check_full(l_repl_current_cnt)               := 'X';
            i := I+1;

        END IF;
       ELSE /*Check Full = 'Y' */
          IF l_repl_current_cnt < l_repl_end_cnt THEN
            l_repl_current_cnt := l_repl_current_cnt + 1;
          ELSE
            l_repl_current_cnt := 1;

          END IF;
       END IF; /*Check Full */
     END LOOP;
     --utl_file.put_line(g_log_fptr, '8');
     --utl_file.fflush(g_log_fptr);

     ELSE /*Scarce Resource */
       LOOP
       EXIT WHEN mt_stock_avail(l_rs_counter) = 0;
       --utl_file.put_line(g_log_fptr, '9');
       --utl_file.fflush(g_log_fptr);

         IF mt_check_full(l_repl_current_cnt) = 'X' THEN
           IF mt_fill_to_model(l_repl_current_cnt) = 'Y' THEN
             IF mt_stock_avail_sku(I) >= mt_ord_qty(l_repl_current_cnt) THEN
               mt_sku1(l_repl_current_cnt)       := mt_sku(I);
               mt_wh1(l_repl_current_cnt)        := mt_wh(I);
               mt_distro_qty(l_repl_current_cnt) := mt_ord_qty(l_repl_current_cnt);
               mt_stock_avail_sku(I)             := mt_stock_avail_sku(I) -
                                                 mt_ord_qty(l_repl_current_cnt);
/********************************************************************
If Stock for the partcular sku finishes increment the pointer to
point to the next sku
********************************************************************/
              IF mt_stock_avail_sku(I) = 0
                 OR mt_stock_avail_sku (i) < v_pack_size
              THEN
                  i := I+1;
              END IF;
              mt_req_qty(l_rs_counter) := mt_req_qty(l_rs_counter) -
                                          mt_ord_qty(l_repl_current_cnt);
              mt_stock_avail(l_rs_counter) := mt_stock_avail(l_rs_counter) -
                                              mt_ord_qty(l_repl_current_cnt);
              mt_check_full(l_repl_current_cnt) := 'Y';
              IF l_repl_current_cnt < l_repl_end_cnt THEN
                 l_repl_current_cnt := l_repl_current_cnt + 1;
              ELSE
                 l_repl_current_cnt := 1;
              END IF;
            ELSE
              l_repl_insert_cnt := l_repl_insert_cnt + 1;
              mt_sku1(l_repl_end_cnt + l_repl_insert_cnt)  := mt_sku(I);
              mt_ord_qty(l_repl_end_cnt+l_repl_insert_cnt) :=
                                                           mt_ord_qty(l_repl_current_cnt);
              mt_distro_qty(l_repl_end_cnt+l_repl_insert_cnt) :=
                                                           mt_stock_avail_sku(I);
              mt_stock_avail(l_rs_counter) := mt_stock_avail(l_rs_counter) -
                                                           mt_stock_avail_sku(I);
                 mt_req(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                           mt_req(l_repl_current_cnt);
                 mt_ord_qty(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                           mt_stock_avail_sku(I) ;
                 mt_ord_qty(l_repl_current_cnt) := mt_ord_qty(l_repl_current_cnt) -
                                                           mt_stock_avail_sku(I) ;
                 mt_repl_skgp1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                           mt_repl_skgp1(l_repl_current_cnt);
                 mt_store(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_store(l_repl_current_cnt);
                 mt_po_line_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_po_line_nbr(l_repl_current_cnt);
                 mt_po_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_po_type(l_repl_current_cnt);
                 mt_stock_on_hand(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_stock_on_hand(l_repl_current_cnt);
                 mt_dist_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_dist_type(l_repl_current_cnt);
                 mt_division(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_division(l_repl_current_cnt);
                 mt_wh1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_wh(I);
                 mt_store_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_store_priority(l_repl_current_cnt);
                 mt_in_str_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_in_str_date(l_repl_current_cnt);
                 mt_distro_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_distro_date(l_repl_current_cnt);
                 mt_cust_name(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_cust_name(l_repl_current_cnt);
                 mt_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_priority(l_repl_current_cnt);
                 mt_watch_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_watch_priority(l_repl_current_cnt);
                 mt_fill_to_model(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_fill_to_model(l_repl_current_cnt);
                 mt_orig_wh(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_orig_wh(l_repl_current_cnt);
                 mt_orig_req(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_orig_req(l_repl_current_cnt);
                 mt_orig_po_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_orig_po_type(l_repl_current_cnt);
                 mt_orig_ord_qty(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              mt_orig_ord_qty(l_repl_current_cnt);
                 mt_pick_process_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                              l_repl_end_cnt+l_repl_insert_cnt;
                 mt_stock_avail_sku(I) := 0;
                 i := I+1;

            END IF;
          ELSIF mt_fill_to_model(l_repl_current_cnt) = 'N' THEN
            IF (mt_sku1(l_repl_current_cnt) = mt_sku(I)
               OR mt_sku1(l_repl_current_cnt) = -1 )THEN
                 IF mt_sku1(l_repl_current_cnt) = -1 THEN
                   mt_sku1(l_repl_current_cnt) := mt_sku(I);
                   mt_wh1(l_repl_current_cnt)  := mt_wh(I);
                 END IF;
                 mt_distro_qty(l_repl_current_cnt) :=
                 mt_distro_qty(l_repl_current_cnt) + v_pack_size; --1;

                 IF mt_distro_qty(l_repl_current_cnt) =
                    mt_ord_qty(l_repl_current_cnt) THEN
                    mt_check_full(l_repl_current_cnt) := 'Y';
                 END IF;
                 IF l_repl_current_cnt < l_repl_end_cnt THEN
                    l_repl_current_cnt := l_repl_current_cnt + 1;
                 ELSE
                    l_repl_current_cnt := 1;
                 END IF;

                 mt_stock_avail_sku(I) := mt_stock_avail_sku(I) - v_pack_size; --1;
                 IF mt_stock_avail_sku(I) = 0
                    OR mt_stock_avail_sku (i) < v_pack_size
                 THEN
                     mt_stock_avail (l_rs_counter) :=   -- pack_size_chg, lines added
                        mt_stock_avail (l_rs_counter)   -- pack_size_chg
                        - mt_stock_avail_sku (i);       -- pack_size_chg
                     mt_stock_avail_sku (i) := 0;       -- pack_size_chg
                      i := I+1;
                 END IF; /* Increasing Stock Counter*/
                 mt_stock_avail(l_rs_counter) := mt_stock_avail(l_rs_counter) - v_pack_size; --1;

                 IF mt_stock_avail (l_rs_counter) < v_pack_size
                    THEN                                         --10 then
                       --UTL_FILE.putf (fptr, '2627 \n');
                       --UTL_FILE.fflush (fptr);
                        mt_stock_avail (l_rs_counter) := 0;
                 END IF;

            ELSE
                 l_repl_insert_cnt := l_repl_insert_cnt + 1;
--                 mt_sku1(l_repl_end_cnt + l_repl_insert_cnt) := mt_sku(I);
--                 mt_wh1(l_repl_end_cnt + l_repl_insert_cnt) := mt_wh(I);
                 mt_sku1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                               mt_sku1(l_repl_current_cnt);
                 mt_wh1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                               mt_wh1(l_repl_current_cnt);
                 mt_ord_qty(l_repl_end_cnt+l_repl_insert_cnt) :=
                                               mt_ord_qty(l_repl_current_cnt);
                 mt_distro_qty(l_repl_end_cnt+l_repl_insert_cnt) :=
                                               mt_distro_qty(l_repl_current_cnt);
                 mt_ord_qty(l_repl_current_cnt) := mt_ord_qty(l_repl_current_cnt) -
                                               mt_distro_qty(l_repl_current_cnt);
                IF mt_distro_qty(l_repl_end_cnt + l_repl_insert_cnt) =
                     mt_ord_qty(l_repl_end_cnt + l_repl_insert_cnt)  THEN
                     mt_check_full(l_repl_end_cnt + l_repl_insert_cnt) := 'Y';
                END IF;

                mt_distro_qty(l_repl_current_cnt) := v_pack_size; --1;
                mt_stock_avail(l_rs_counter) := mt_stock_avail(l_rs_counter) - v_pack_size; --1;
/* Checking to see that the current line is full or not */
                IF mt_distro_qty(l_repl_current_cnt) =
                  mt_ord_qty(l_repl_current_cnt) THEN
                  mt_check_full(l_repl_current_cnt) := 'Y';
                END IF;

                   mt_req(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                     mt_req(l_repl_current_cnt);
                   mt_repl_skgp1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                     mt_repl_skgp1(l_repl_current_cnt);
                   mt_store(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_store(l_repl_current_cnt);
                   mt_po_line_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_po_line_nbr(l_repl_current_cnt);
                   mt_po_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_po_type(l_repl_current_cnt);
                   mt_stock_on_hand(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_stock_on_hand(l_repl_current_cnt);
                   mt_dist_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_dist_type(l_repl_current_cnt);
                   mt_division(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_division(l_repl_current_cnt);
                   mt_wh1(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_wh1(l_repl_current_cnt);
                   mt_store_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_store_priority(l_repl_current_cnt);
                   mt_in_str_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_in_str_date(l_repl_current_cnt);
                   mt_distro_date(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_distro_date(l_repl_current_cnt);
                   mt_cust_name(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_cust_name(l_repl_current_cnt);
                   mt_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_priority(l_repl_current_cnt);
                   mt_watch_priority(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_watch_priority(l_repl_current_cnt);
                   mt_fill_to_model(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_fill_to_model(l_repl_current_cnt);
                   mt_orig_wh(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_orig_wh(l_repl_current_cnt);
                   mt_orig_req(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_orig_req(l_repl_current_cnt);
                   mt_orig_po_type(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_orig_po_type(l_repl_current_cnt);
                   mt_orig_ord_qty(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        mt_orig_ord_qty(l_repl_current_cnt);
                   mt_pick_process_nbr(l_repl_end_cnt + l_repl_insert_cnt) :=
                                                        l_repl_end_cnt + l_repl_insert_cnt;
                mt_sku1(l_repl_current_cnt)       := mt_sku(I);
                mt_wh1(l_repl_current_cnt)        := mt_wh(I);
                mt_stock_avail_sku(I)             := mt_stock_avail_sku(I) - v_pack_size; --1;
                IF mt_stock_avail_sku(I) = 0
                   OR mt_stock_avail_sku (i) < v_pack_size
                THEN
                   i := I+1;
                END IF; /* Increasing Stock Counter*/
/****************************************************************************/
                IF l_repl_current_cnt < l_repl_end_cnt THEN
                   l_repl_current_cnt := l_repl_current_cnt + 1;
                ELSE
                l_repl_current_cnt := 1;
              END IF; /*Counter Increment */
/****************************************************************************/

            END IF;
          END IF;/* Process For Check Full = 'X'  AND FILL TO  MODEL = 'N'*/
        ELSE /*Check Full = 'Y' */
          IF l_repl_current_cnt < l_repl_end_cnt THEN
            l_repl_current_cnt := l_repl_current_cnt + 1;
          ELSE
            l_repl_current_cnt := 1;

          END IF;

        END IF;
      END LOOP;
   END IF;
   l_repl_cnt := l_repl_end_cnt + l_repl_insert_cnt;

   --utl_file.put_line(g_log_fptr, '10');
   --utl_file.fflush(g_log_fptr);

   DELETE FROM ZMS_ZPF_DIV_EXTRACT
    WHERE repl_sku_group = l_repl_sku_group
      AND orig_wh        = l_repl_orig_wh
      AND SKU = -1;

   --utl_file.put_line(g_log_fptr, '11 - '|| l_repl_cnt);
   --utl_file.fflush(g_log_fptr);

   FOR I IN 1..l_repl_cnt
   LOOP
     --utl_file.put_line(g_log_fptr, '12 - '|| l_repl_cnt);
     --utl_file.fflush(g_log_fptr);

     INSERT INTO ZMS_ZPF_DIV_EXTRACT
       (STORE, SKU, REQ, DIVISION, ord_qty, stock_on_hand,
        repl_sku_group, po_type, po_line_nbr, store_priority,
        in_str_date, PRIORITY, watch_priority,
        dist_type, WH, request_sku, distro_date, cust_name,
        orig_wh, orig_req, orig_po_type, orig_ord_qty, pick_process_nbr
        --,
        --stock_avail
        )
     VALUES(mt_store(I),mt_sku1(I),mt_req(I),mt_division(I),mt_distro_qty(I), mt_stock_on_hand(I),
            mt_repl_skgp1(I),mt_po_type(I), mt_po_line_nbr(I),mt_store_priority(I),
            mt_in_str_date(I),mt_priority(I),mt_watch_priority(I),
            mt_dist_type(I), NVL(mt_wh1(I),0), mt_repl_skgp1(I), mt_distro_date(I), mt_cust_name(I),
            mt_orig_wh(I), mt_orig_req(I), mt_orig_po_type(I), mt_orig_ord_qty(I), mt_pick_process_nbr(I)
            --,
        --  mt_stock_avail_sku(i)+mt_distro_qty(i)
            );
   END LOOP;
     --utl_file.put_line(g_log_fptr, '13');
     --utl_file.fflush(g_log_fptr);

   l_repl_insert_cnt := 0;
   l_repl_end_cnt := 0;
   l_repl_start_cnt := 0;
   l_repl_cnt := 0 ;
   l_repl_current_cnt := 0;
   /* Decrement the Stock in Sku from zms_zpf_win_wh */
   /*Initialize Stock Matrix */
   FOR I IN 1..l_stk_end
   LOOP
     UPDATE ZMS_ZPF_WIN_WH
        SET stock_avail = mt_stock_avail_sku(I)
      WHERE SKU = mt_sku(I)
        AND WH  = mt_wh(I);  --IN (SELECT WH FROM WH WHERE wh_type_no = 0);  --WH = 8904;
     mt_sku(I) := 0;
     mt_stock_avail_sku(I) := 0;
   END LOOP;
     --utl_file.put_line(g_log_fptr, '14');
     --utl_file.fflush(g_log_fptr);

   /*Initialze Stck Counters */
   l_stk_start := 0;
   l_stk_cnt := 0;
   l_stk_end := 0;
   l_tot_stock := 0;
  END LOOP;
   /*Delete all records which have not been picked */
  DELETE FROM ZMS_ZPF_DIV_EXTRACT
     WHERE  SKU = -1;
  IF (NOT  p_is_forecast ) THEN
        /* Update zl_process_extract_check.SKU_GROUP_PROC to 'Y' if this procedure is
           finished successfully   added by Prasad */
--        UPDATE ZL_PROCESS_EXTRACT_CHECK SET SKU_GROUP_PROC = 'Y' ;
        COMMIT;
/*      p_update_feedback_reqdetail;  */ /*will be called from proC*/
  END IF;/*End of NOT p_forecast */
  utl_file.putf(fptr,'I am Done!! ,bye\n');
  utl_file.fflush(fptr);
  utl_file.fclose(fptr);
--utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - zpf end:'));

  utl_file.put_line(g_log_fptr,'====================================================================');
  utl_file.fflush(g_log_fptr);
  utl_file.fclose(g_log_fptr);

EXCEPTION

   WHEN no_sku_groups THEN
        utl_file.put_line(g_log_fptr,'====================================================================');
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        NULL;

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_alloc_sku_groups';
        O_err_code := 20106;
        utl_file.put_line(g_log_fptr, O_error_message);
        utl_file.put_line(g_log_fptr, 'l_repl_orig_wh - '|| l_repl_orig_wh ||'  l_repl_sku_group - ' || NVL(l_repl_sku_group,-2) || '  mt_sku1(l_repl_cnt) - ' || NVL(mt_sku1(l_repl_cnt),-2) || '  mt_wh1(l_repl_cnt) - ' || NVL(mt_wh1(l_repl_cnt),-2));
        utl_file.fflush(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20106,SQLERRM);

END p_zpf_alloc_sku_groups;

/***************************************************************************
The following procedure will update the feedback reqdetail tables
*****************************************************************************/
PROCEDURE p_zpf_upd_feedback_reqdetail(O_err_code OUT INTEGER) IS

   O_error_message  VARCHAR2(2000);

BEGIN

g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_zpf_upd_feedback_reqdetail started:'));

/******************************************************************/
/* Create New Transfers for Akron and SJIL                        */
/* Update cancel_qty on Zale Transfers                            */
/******************************************************************/

    -- Everything should be allocated by now
     DELETE FROM ZMS_ZPF_DIV_EXTRACT zpf
           WHERE zpf.ord_qty =  0
              OR zpf.SKU     = -1;

     EXECUTE IMMEDIATE 'truncate table zms_zpf_new_tsf_no drop storage';

     -- Assign new transfer numbers for records where orig_wh
     INSERT INTO zms_zpf_new_tsf_no
        (wh, store, req, cust_name)
        (SELECT wh, store, transfer_number_sequence.nextval new_req, cust_name
           FROM (SELECT DISTINCT wh, store, cust_name
                   FROM zms_zpf_div_extract
                  WHERE orig_wh <> wh));

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Create New TSF Numbers: '||SQL%ROWCOUNT));

     MERGE INTO zms_zpf_div_extract zpf USING
        (SELECT a.wh, a.store, a.orig_wh, a.sku, a.po_type,
                a.orig_req, a.orig_po_type, b.req, b.cust_name
           FROM zms_zpf_div_extract a, zms_zpf_new_tsf_no b
          WHERE a.wh        = b.wh
            AND a.store     = b.store
            AND NVL(a.cust_name,' ') = NVL(b.cust_name,' ')
            AND a.orig_wh <> a.wh) dt
     ON(zpf.wh = dt.wh and zpf.store = dt.store and zpf.orig_wh = dt.orig_wh and
        zpf.sku = dt.sku and zpf.orig_req = dt.orig_req and NVL(zpf.cust_name,' ') = NVL(dt.cust_name,' '))
     WHEN MATCHED THEN
     UPDATE
     SET zpf.req = dt.req;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Assign New TSF Numbers to zpf_div_extract: '||SQL%ROWCOUNT));

     INSERT INTO tsfhead
        (tsf_no, tsf_parent_no, from_loc_type, from_loc,
         to_loc_type, to_loc, exp_dc_date, dept, inventory_type, tsf_type,
         status, freight_code, routing_code, create_date,
         create_id, approval_date, approval_id, delivery_date,
         close_date, ext_ref_no, repl_tsf_approve_ind, comment_desc,
         exp_dc_eow_date, mrt_no, not_after_date, context_type,
         context_value, restock_pct, wf_need_date, delivery_slot_id, order_no)
     SELECT DISTINCT zpf.req tsf_no, NULL tsf_parent_no, 'W' from_loc_type, zpf.wh||'1001' from_loc,
         'S' to_loc_type, zpf.store to_loc, NULL exp_dc_date, NULL dept, 'A' inventory_type,
         'MR' tsf_type, 'L' status, 'N' freight_code, NULL routing_code, get_vdate create_date,
         'PICKGEN' create_id, get_vdate approval_date, 'PICKGEN' approval_id, get_vdate+2 delivery_date,
         NULL close_date, NULL ext_ref_no, 'N' repl_tsf_approve_ind,
         cust_name comment_desc, NULL exp_dc_eow_date, NULL mrt_no, NULL not_after_date, NULL context_type,
         NULL context_value, NULL restock_pct, NULL wf_need_date, NULL delivery_slot_id, NULL order_no
       FROM zms_zpf_div_extract zpf
      WHERE zpf.orig_wh <> zpf.wh
      ORDER BY zpf.wh||'1001', zpf.store;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Create new tsfhead where orig_wh <> wh: '||SQL%ROWCOUNT));

     INSERT INTO tsfdetail
        (tsf_no, tsf_seq_no, item, inv_status, tsf_price, tsf_qty, fill_qty,
         ship_qty, received_qty, reconciled_qty, distro_qty, selected_qty,
         cancelled_qty, supp_pack_size, tsf_po_link_no, default_chrgs_2_leg_ind,
         mbr_processed_ind, publish_ind, tsf_cost, restock_pct, finisher_av_retail,
         finisher_units, updated_by_rms_ind, cust_ord_tsf_unit_retail,
         cust_ord_tsf_unit_retail_curr, cust_ord_tsf_total_retail,
         cust_ord_tsf_total_retail_curr)
     SELECT a.req tsf_no, (1000000 + rownum) tsf_seq_no, a.request_sku item, NULL inv_status, NULL tsf_price, a.ord_qty tsf_qty, 0 fill_qty,
            NULL ship_qty, NULL received_qty, NULL reconciled_qty, a.ord_qty distro_qty, NULL selected_qty,
            0 cancelled_qty, 1 supp_pack_size, 0 tsf_po_link_no, NULL default_chrgs_2_leg_ind,
            'Y' mbr_processed_ind, 'N' publish_ind, NULL tsf_cost, NULL restock_pct, NULL finisher_av_retail,
            NULL finisher_units, 'Y' updated_by_rms_ind, NULL cust_ord_tsf_unit_retail,
            NULL cust_ord_tsf_unit_retail_curr, NULL cust_ord_tsf_total_retail,
            NULL cust_ord_tsf_total_retail_curr
       FROM (SELECT zpf.req, zpf.request_sku, SUM(zpf.ord_qty) ord_qty
               FROM zms_zpf_div_extract zpf
              WHERE zpf.orig_wh <> zpf.wh
              GROUP BY zpf.req, zpf.request_sku) a
      ORDER BY a.req, a.request_sku;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Create new tsfdetail where orig_wh <> wh: '||SQL%ROWCOUNT));

     -- Update tsf_expected on item_loc_soh for Store
--     MERGE INTO item_loc_soh ils USING
--        (SELECT zpf.store, zpf.sku, SUM(NVL(zpf.ord_qty,0)) ord_qty
--           FROM zms_zpf_div_extract zpf
--          WHERE zpf.orig_wh <> zpf.wh
--          GROUP BY zpf.wh, zpf.sku) dt
--     ON(ils.loc = dt.wh and ils.item = dt.sku)
--     WHEN MATCHED THEN
--     UPDATE
--     SET ils.tsf_expected_qty = ils.tsf_expected_qty + dt.ord_qty;

--     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsf_expected on item_loc_soh for Store: '||SQL%ROWCOUNT));

     -- Update tsf_reserve on item_loc_soh for New WH
     MERGE INTO item_loc_soh ils USING
        (SELECT TO_NUMBER(zpf.wh||'1001') wh, zpf.request_sku, SUM(NVL(zpf.ord_qty,0)) ord_qty
           FROM zms_zpf_div_extract zpf
          WHERE zpf.orig_wh <> zpf.wh
          GROUP BY zpf.wh, zpf.request_sku) dt
     ON(ils.loc = dt.wh and ils.item = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_reserved_qty = ils.tsf_reserved_qty + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsf_reserve on item_loc_soh for Akron WH: '||SQL%ROWCOUNT));

     -- Update tsf_resserve on item_loc_soh for Orig WH - Use tsf_qty due to inner_pack_size
     MERGE INTO item_loc_soh ils USING
        (SELECT TO_NUMBER(zpf.orig_wh||'1001') wh, zpf.request_sku, SUM(NVL(td.tsf_qty,0)) tsf_qty
           FROM zms_zpf_div_extract zpf, tsfdetail td
          WHERE zpf.orig_req    = td.tsf_no
            AND zpf.request_sku = td.item
            AND zpf.orig_wh    <> zpf.wh
          GROUP BY zpf.orig_wh, zpf.request_sku) dt
     ON(ils.loc = dt.wh and ils.item = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_reserved_qty = NVL(ils.tsf_reserved_qty,0) - dt.tsf_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsf_reserve on item_loc_soh for Dallas WH: '||SQL%ROWCOUNT));

     -- Update cancelled_qty on original replenishment transfers
     MERGE INTO tsfdetail td USING
        (SELECT zpf.orig_req, zpf.request_sku, SUM(NVL(zpf.ord_qty,0)) ord_qty
           FROM zms_zpf_div_extract zpf
          WHERE zpf.orig_wh  <> zpf.wh
            AND zpf.orig_req <> zpf.req
            AND zpf.po_type   = 'T'
          GROUP BY zpf.orig_req, zpf.request_sku) dt
     ON(td.tsf_no = dt.orig_req and td.item = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET td.cancelled_qty = CASE WHEN NVL(td.tsf_qty,0) <= dt.ord_qty THEN NVL(td.cancelled_qty,0) + NVL(td.tsf_qty,0)
                                 ELSE NVL(td.cancelled_qty,0) + dt.ord_qty
                                 END,
         td.tsf_qty       = CASE WHEN NVL(td.tsf_qty,0) <= dt.ord_qty THEN 0
                                 ELSE NVL(td.tsf_qty,0)  - dt.ord_qty
                                 END;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update cancelled_qty on Dallas Transfers: '||SQL%ROWCOUNT));

     -- Update cancelled_qty on original allocations
     MERGE INTO alloc_detail ad USING
        (SELECT zpf.orig_req, zpf.store, SUM(NVL(zpf.ord_qty,0)) ord_qty
           FROM zms_zpf_div_extract zpf
          WHERE zpf.orig_wh     <> zpf.wh
            AND zpf.orig_req    <> zpf.req
            AND zpf.orig_po_type = 'A'
          GROUP BY zpf.orig_req, zpf.store) dt
     ON(ad.alloc_no = dt.orig_req and ad.to_loc = dt.store)
     WHEN MATCHED THEN
     UPDATE
     SET ad.qty_cancelled = NVL(ad.qty_cancelled,0) + dt.ord_qty,
         ad.qty_allocated = NVL(ad.qty_allocated,0) - dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update cancelled_qty on Dallas Allocations: '||SQL%ROWCOUNT));

     INSERT INTO zms_ifo_pick_div_extract
        (sku, wh, store, tsf_type, distro_type,
         ord_qty, req, division, request_sku, distro_date, cust_name, data_source)
        SELECT zpf.sku, zpf.wh, zpf.store, zpf.po_type tsf_type, DECODE(zpf.dist_type,'SO','SO','RP') dist_type,
               SUM(zpf.ord_qty), zpf.req, zal2.store_div division, zpf.request_sku, zpf.distro_date, zpf.cust_name, 'RMS' data_source
          FROM zms_zpf_div_extract zpf, zms_all_location zal1, zms_all_location zal2
         WHERE zpf.wh           = zal1.loc_four_digit
           AND zpf.store        = zal2.loc
           AND zal1.akron_wh_ind = 'Y'
         GROUP BY zpf.sku, zpf.wh, zpf.store, zpf.po_type, DECODE(zpf.dist_type,'SO','SO','RP'),
                  zpf.req, zal2.store_div, zpf.request_sku, zpf.distro_date, zpf.cust_name;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Insert Into zms_ifo_pick_div_extract table: '||SQL%ROWCOUNT));

/******************************************************************/
/* Update FeedBack Table                                          */
/*                                                                */
/******************************************************************/
/*
     DELETE FROM ZMS_ZALE_FEEDBACK
      WHERE (REQ,SKU,STORE,repl_sku_group) IN
       (SELECT REQ,SKU,STORE,repl_sku_group
          FROM ZMS_ZPF_DIV_EXTRACT);

     INSERT INTO ZMS_ZALE_FEEDBACK
           (REQ,SKU,STORE,repl_sku_group,dcs_pick_qty,dcs_pick_dt,
            dcs_unpicked_qty,priority,TYPE, WH)
     SELECT REQ,SKU,STORE,repl_sku_group,ord_qty,SYSDATE,
            --ord_qty,priority,'S'  --'I'  J.P. 12/2005
            ord_qty,priority,'I'
            , WH
       FROM ZMS_ZPF_DIV_EXTRACT;
*/
     /*Update reqdetail Table */
--sa     UPDATE REQDETAIL@over_to_rtkp SET sel_for_pick = 'Y'
--sa      WHERE (REQ ,SKU,repl_sku_group,STORE) IN
--sa            (SELECT REQ,DECODE(repl_sku_group,-1,SKU,-1) ,
--sa                    repl_sku_group,STORE
--sa               FROM ZMS_ZPF_DIV_EXTRACT);


/******************************************************************/
/* Update Initially Created Replenishment Transfers               */
/*                                                                */
/******************************************************************/

     MERGE INTO alloc_detail ad USING
     (SELECT zpf.req, zpf.store, zpf.po_type, SUM(zpf.ord_qty) ord_qty
        FROM zms_zpf_div_extract zpf
       WHERE zpf.po_type = 'A'
       GROUP BY zpf.req, zpf.store, zpf.po_type) dt
     ON(ad.alloc_no = dt.req AND
        ad.to_loc   = dt.store)
     WHEN MATCHED THEN
     UPDATE
     SET ad.qty_distro = NVL(ad.qty_distro,0) + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update Allocation qty_distro: '||SQL%ROWCOUNT));

     MERGE INTO tsfdetail td USING
     (SELECT zpf.req, zpf.request_sku, SUM(zpf.ord_qty) ord_qty
       FROM zms_zpf_div_extract zpf
      WHERE zpf.po_type = 'T'
        AND zpf.wh = zpf.orig_wh
      GROUP BY zpf.req, zpf.request_sku) dt
      ON(td.tsf_no = dt.req AND
         td.item   = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET td.distro_qty = NVL(td.distro_qty,0) + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsfdetail distro_qty: '||SQL%ROWCOUNT));

     MERGE INTO tsfhead th USING
     (SELECT DISTINCT zpf.req, zpf.po_type
        FROM zms_zpf_div_extract zpf
       WHERE zpf.po_type = 'T'
         AND zpf.wh = zpf.orig_wh) dt
     ON (th.tsf_no = dt.req)
     WHEN MATCHED THEN
     UPDATE
     SET th.status = 'L'
     WHERE th.status <> 'S';

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsfhead status to L: '||SQL%ROWCOUNT));

    UPDATE zms_ifi_pick_sku_override so
       SET so.process_status = 'P',
           so.processed_date = SYSDATE
     WHERE so.process_status = 'I';

    UPDATE zms_ifi_pick_dept_override do
       SET do.process_status = 'P',
           do.processed_date = SYSDATE
     WHERE do.process_status = 'I';

    UPDATE zms_ifi_pick_store_override so
       SET so.process_status = 'P',
           so.processed_date = SYSDATE
     WHERE so.process_status = 'I';

    UPDATE zms_ifi_pick_store_group sg
       SET sg.process_status = 'P',
           sg.processed_date = SYSDATE
     WHERE sg.process_status = 'I';

     COMMIT;

     utl_file.put_line(g_log_fptr,'====================================================================');
     utl_file.fflush(g_log_fptr);
     utl_file.fclose(g_log_fptr);

EXCEPTION

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_zpf_upd_feedback_reqdetail';
        O_err_code := 20107;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20106,SQLERRM);

END p_zpf_upd_feedback_reqdetail;
---------------------------------
PROCEDURE p_zpf_alloc_sku_groups_fcast IS
   l_stock_avail    ZMS_ZPF_WIN_WH.stock_avail%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_ord_qty        ZMS_ZPF_DIV_EXTRACT.ord_qty%TYPE;
   l_pick_priority sub_items_detail.pick_priority%TYPE;

   TYPE t_sku IS TABLE OF
        ZMS_ZPF_DIV_EXTRACT.SKU%TYPE
   INDEX BY BINARY_INTEGER;

   TYPE t_stock_avail IS TABLE OF
        ZMS_ZPF_WIN_WH.stock_avail%TYPE
   INDEX BY BINARY_INTEGER;

   mt_sku t_sku;
   mt_stock_avail t_stock_avail;
   i BINARY_INTEGER := 0;
   l_curr_sku BINARY_INTEGER := 0;

   CURSOR c_get_zpf_div_extract_repl IS
   SELECT /*+ index (R REQDETAIL_I2) */
          z.REQ,
          z.SKU,
          z.ord_qty,
          z.repl_sku_group,
          z.STORE,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          --DECODE(z.stock_on_hand,0, 'A','B') out_of_stock,
          z.po_line_nbr,
          z.po_type,
          z.DIVISION,
          z.store_priority,
          z.in_str_date,
          z.distro_date,
          z.priority,
          z.watch_priority,
          z.ROWID myrow
     FROM ZMS_ZPF_DIV_EXTRACT z,
          (SELECT DISTINCT item FROM sub_items_head) sih
   WHERE z.SKU            = -1
     AND z.repl_sku_group = l_repl_sku_group
     AND z.repl_sku_group = sih.item
   ORDER BY z.priority,
         out_of_stock,
         z.ord_qty DESC,
         z.stock_on_hand,
         z.REQ,
         z.store;

   CURSOR c_get_sku_groups  IS
   SELECT repl_sku_group,SUM(NVL(ord_qty,0)) req_qty
     FROM ZMS_ZPF_DIV_EXTRACT
    WHERE SKU = -1
    GROUP BY repl_sku_group;

   CURSOR c_get_stk_matrix IS
   SELECT zms.sub_item SKU,
          NVL(stock_avail,0) stock_avail,
          zms.item_pick_priority
     FROM ZMS_ZPF_WIN_WH wwz, zms_zpf_main_sub zms
    WHERE wwz.SKU = zms.sub_item
      AND zms.item = l_repl_sku_group
    ORDER BY zms.item_pick_priority;
BEGIN
   /******************************************************************/
  /* loop through all repl_sku_group records.  process each         */
   /******************************************************************/
 FOR l_get_repl IN c_get_sku_groups
 LOOP
  l_repl_sku_group := l_get_repl.repl_sku_group;
  l_ord_qty  := l_get_repl.req_qty;
   /*****************************************************************
         Prepare Stock Matrix
  *********************************************************************/
  l_stock_avail := 0; /*Initialize*/

  i := 0;
  FOR l_matrix IN c_get_stk_matrix
  LOOP
    i := i+1;
    l_stock_avail := l_stock_avail + l_matrix.stock_avail;
    mt_sku(i) := l_matrix.SKU;
    mt_stock_avail(i) := l_matrix.stock_avail;
  END LOOP;

  l_curr_sku := 1;
  IF  (l_stock_avail < l_ord_qty) THEN
   FOR l_div_rec IN c_get_zpf_div_extract_repl
   LOOP
     IF (l_stock_avail <= 0)  THEN
       DELETE FROM ZMS_ZPF_DIV_EXTRACT
        WHERE ROWID = l_div_rec.myrow;
     ELSIF  (l_div_rec.ord_qty > l_stock_avail) THEN
       UPDATE ZMS_ZPF_DIV_EXTRACT
          SET ord_qty = l_stock_avail,
              SKU = mt_sku(l_curr_sku),
              stock_avail = l_stock_avail
        WHERE ROWID = l_div_rec.myrow;

       l_stock_avail := 0;
       mt_stock_avail(l_curr_sku) := 0;
       IF mt_stock_avail(l_curr_sku) = 0 THEN
         l_curr_sku := l_curr_sku + 1;
       END IF;
     ELSE
       UPDATE ZMS_ZPF_DIV_EXTRACT
          SET SKU = mt_sku(l_curr_sku)
        WHERE ROWID = l_div_rec.myrow;
       l_stock_avail := l_stock_avail - l_div_rec.ord_qty;
       mt_stock_avail(l_curr_sku) := mt_stock_avail(l_curr_sku)
                             - l_div_rec.ord_qty;
       IF mt_stock_avail(l_curr_sku) <= 0 THEN
         IF l_curr_sku < i THEN
            l_curr_sku := l_curr_sku + 1;
            mt_stock_avail(l_curr_sku) := mt_stock_avail(l_curr_sku)
                      - mt_stock_avail(l_curr_sku -1);
         END IF;
       END IF;
     END IF;
   END LOOP;
  ELSE
    UPDATE ZMS_ZPF_DIV_EXTRACT
       SET SKU = mt_sku(l_curr_sku)
     WHERE repl_sku_group = l_repl_sku_group;
  END IF; /*scarce Resource*/
 END LOOP;     /* l_get_repl */
END p_zpf_alloc_sku_groups_fcast;

-----------------------------------------------------------
-----------------------------------------------------------

PROCEDURE P_zpf_e3_EXCEEDED_MAX_PICK(return_code IN OUT VARCHAR2, O_error_message IN OUT VARCHAR2) IS

   l_req_qty        NUMBER;
   l_boolean        BOOLEAN;
   l_wh             item_loc_soh.loc%TYPE;
   l_current_pick   item_loc_soh.stock_on_hand%TYPE;
   l_req            alloc_header.alloc_no%TYPE;
   l_sku            item_master.item%TYPE;
   l_store          STORE.STORE%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_max_pick_qty   ZMS_ZPF_NOPICK_REPORT.pick_qty%TYPE;
   l_nopick_rowid   ROWID;

   CURSOR c_get_pick_limit IS
   SELECT flex_num2 quantity, flex_num WH
     FROM ZMS_STORE_FLEX_VALUES
    WHERE flex_type = 'max_qty_pick';

   CURSOR c_get_qty_req IS
   SELECT SUM(ord_qty)
     FROM ZMS_ZPF_DIV_EXTRACT;


   CURSOR c_req_records IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
        ZMS_ZPF_DCS_DIV zdd
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       = l_wh
   ORDER BY z.REQ DESC,
         zdd.priority,                /* divisional priority */
         z.priority,                  /* type of request     */
         z.ord_qty DESC;

   CURSOR c_req_records_8591 IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.repl_sku_group,
          z.ord_qty
   FROM ZMS_ZPF_DIV_EXTRACT z,
        ZMS_ZPF_DCS_DIV zdd
   WHERE z.DIVISION = zdd.DIVISION
     AND z.WH       = zdd.WH
     AND z.WH       IN (8904, 8591)
   ORDER BY z.REQ DESC,
         zdd.priority,          /* divisional priority */
         z.priority,                  /* type of request     */
         z.ord_qty DESC;
BEGIN
   FOR limit_rec IN c_get_pick_limit
   LOOP
     BEGIN
     l_wh := limit_rec.WH;
     l_max_pick_qty := limit_rec.quantity;
     IF l_wh = 8904 THEN
        SELECT SUM(ord_qty)
          INTO l_req_qty
          FROM ZMS_ZPF_DIV_EXTRACT
         WHERE WH IN (8904, 8591);
     ELSE
        SELECT SUM(ord_qty)
          INTO l_req_qty
          FROM ZMS_ZPF_DIV_EXTRACT
         WHERE WH = l_wh;
     END IF;
     EXCEPTION
      WHEN OTHERS THEN
        O_error_message := SQLERRM || ' WHEN selecting FROM ZMS_ZPF_DIV_EXTRACT TABLE';
        return_code := 'FALSE';
     END;
     IF (l_max_pick_qty < NVL(l_req_qty,0)) THEN
--        P_zpf_e3_REDUCE_TO_MAX_PICK(l_max_pick_qty, l_wh);

      l_current_pick := 0;

      IF l_wh = 8904 THEN
       FOR l_req_records IN c_req_records_8591
          LOOP
        p_zpf_e3_reduce_to_max_by_wh(l_max_pick_qty,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
--utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - curr pick '||l_current_pick||', MAX '||pm_max_pick));
       END LOOP;
      ELSE
       FOR l_req_records IN c_req_records
       LOOP

        p_zpf_e3_reduce_to_max_by_wh(l_max_pick_qty,
                          l_req_records.REQ,
                          l_req_records.SKU,
                          l_req_records.STORE,
                          l_req_records.repl_sku_group,
                          l_req_records.ord_qty,
                          l_current_pick);
       END LOOP;
      END IF;
     ELSE
        NULL;   /*Do Nothing*/
     END IF;
    END LOOP;
    return_code := 'TRUE';

EXCEPTION

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem IN p_zpf_e3_exceeded_max_pick';
        return_code := 'FALSE';

END P_zpf_e3_EXCEEDED_MAX_PICK;

----------------------------------------------------------------------
/***************************************************************/
PROCEDURE p_zpf_e3_reduce_to_max_by_wh (pm_max_pick IN NUMBER,
                                 pm_req      IN NUMBER,
                                 pm_sku      IN NUMBER,
                                 pm_store    IN NUMBER,
                                 pm_repl_sku_group IN NUMBER,
                                 pm_ord_qty  IN NUMBER,
                                 pm_current_pick IN OUT NUMBER) IS
--   l_current_pick   item_loc_soh.stock_on_hand%TYPE ;
   l_req            alloc_header.alloc_no%TYPE;
   l_sku            item_master.item%TYPE;
   l_store          STORE.STORE%TYPE;
   l_repl_sku_group ZMS_ZPF_DIV_EXTRACT.repl_sku_group%TYPE;
   l_pick_qty       ZMS_ZPF_NOPICK_REPORT.pick_qty%TYPE;
   l_nopick_rowid   ROWID;
   l_ord_qty        NUMBER;
   l_max_pick       NUMBER;


   CURSOR c_zpf_nopick_report IS
   SELECT pick_qty, ROWID
     FROM ZMS_ZPF_NOPICK_REPORT
    WHERE REQ   = pm_req
      AND STORE = pm_store
      AND SKU   = pm_sku
      AND repl_sku_group = pm_repl_sku_group;
BEGIN
      l_max_pick := pm_max_pick ;
      l_req      := pm_req;
      l_sku      := pm_sku;
      l_store    := pm_store;
      l_repl_sku_group := pm_repl_sku_group;
      l_ord_qty  := pm_ord_qty;
--      l_current_pick   := pm_current_pick;
      /***************************************************************/
      /* IF (we have already met the maximum pick) then delete the   */
      /*    record                                                   */
      /***************************************************************/
      IF (pm_current_pick = pm_max_pick) THEN
         IF pm_req <> 999888 THEN
          IF (pm_repl_sku_group = -1) THEN
            UPDATE ZMS_ZPF_NOPICK_REPORT
               SET pick_qty = 0,
                   reason_code = 'XMAX'
             WHERE REQ   = pm_REQ
               AND STORE = pm_STORE
               AND SKU   = pm_sku
               AND repl_sku_group = pm_repl_sku_group;

          ELSE
            l_req := pm_REQ;
            l_sku := pm_sku;
            l_store := pm_STORE;
            l_repl_sku_group := pm_repl_sku_group;
            --l_pick_qty := pm_pick_qty;

            OPEN c_zpf_nopick_report;
            FETCH c_zpf_nopick_report
            INTO l_pick_qty, l_nopick_rowid;
            IF c_zpf_nopick_report%FOUND THEN
              l_pick_qty := l_pick_qty - pm_ord_qty;

              UPDATE ZMS_ZPF_NOPICK_REPORT
                 SET pick_qty = l_pick_qty
               WHERE ROWID = l_nopick_rowid;
            END IF;
            CLOSE c_zpf_nopick_report;
          END IF;
         END IF;

         INSERT INTO ZMS_ZL_DROP_OVERMAX
          (SELECT STORE, SKU, REQ, po_line_nbr, po_type, DIVISION,
                  (ord_qty - (pm_max_pick - pm_current_pick)),
                  store_priority, in_str_date, priority, repl_sku_group,
                  watch_priority, dist_type, WH
             FROM ZMS_ZPF_DIV_EXTRACT
            WHERE STORE = l_STORE
              AND SKU   = l_sku
              AND REQ   = l_REQ
              AND repl_sku_group = l_repl_sku_group);

         DELETE FROM ZMS_ZPF_DIV_EXTRACT
          WHERE STORE = l_STORE
            AND SKU   = l_sku
            AND REQ   = l_REQ
            AND repl_sku_group = l_repl_sku_group;
      /***************************************************************/
      /* else IF (the request quantity is bigger than the amount     */
      /*    left in the maximum pick) then reduce the request        */
      /*    quantity to the amount left                              */
      /***************************************************************/
      ELSIF (l_ord_qty >(pm_max_pick - pm_current_pick)) THEN
         IF pm_req <> 999888 THEN
          IF (l_repl_sku_group = -1) THEN
            UPDATE ZMS_ZPF_NOPICK_REPORT
               SET pick_qty = 0,
                   reason_code = 'XMAX'
             WHERE REQ   = pm_REQ
               AND STORE = pm_STORE
               AND SKU   = pm_sku
               AND repl_sku_group = pm_repl_sku_group;
          ELSE
            l_req := pm_REQ;
            l_sku := pm_sku;
            l_store := pm_STORE;
            l_repl_sku_group := pm_repl_sku_group;

            OPEN c_zpf_nopick_report;
            FETCH c_zpf_nopick_report
             INTO l_pick_qty, l_nopick_rowid;

            IF c_zpf_nopick_report%FOUND THEN
              l_pick_qty := l_pick_qty - (pm_max_pick - pm_current_pick);
              UPDATE ZMS_ZPF_NOPICK_REPORT
                 SET pick_qty = l_pick_qty
               WHERE ROWID = l_nopick_rowid;
            END IF;
            CLOSE c_zpf_nopick_report;
          END IF;
         END IF;

         INSERT INTO ZMS_ZL_DROP_OVERMAX
          (SELECT STORE, SKU, REQ, po_line_nbr, po_type, DIVISION,
                  (ord_qty - (pm_max_pick - pm_current_pick)),
                  store_priority, in_str_date, priority, repl_sku_group,
                  watch_priority, dist_type, WH
             FROM ZMS_ZPF_DIV_EXTRACT
            WHERE STORE = l_STORE
              AND SKU   = l_sku
              AND REQ   = l_REQ
              AND repl_sku_group = l_repl_sku_group);

         UPDATE ZMS_ZPF_DIV_EXTRACT
            SET ord_qty = pm_max_pick - pm_current_pick,
                stock_avail = -8888888
            WHERE REQ   = l_REQ
            AND STORE   = l_STORE
            AND SKU     = l_sku
            AND repl_sku_group = l_repl_sku_group;

         pm_current_pick := pm_max_pick;
      /***************************************************************/
      /* else(there is more left in the current pick than the       */
      /*    current request) so add the amount of the current request*/
      /*    to the current amount picked                             */
      /***************************************************************/
      ELSE
         pm_current_pick := pm_current_pick + pm_ord_qty;
      /***************************************************************/
      /* end IF (we have already met the maximum pick)               */
      /***************************************************************/
      END IF;

EXCEPTION

    WHEN OTHERS THEN
         RAISE_APPLICATION_ERROR (-20108,SQLERRM);

END p_zpf_e3_reduce_to_max_by_wh;


END zpf;
/