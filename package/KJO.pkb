CREATE OR REPLACE PACKAGE BODY ZMS.kjo IS

---------------------------------------------------------------------------------
-- GLOBAL VARIABLE DECLARATIONS
---------------------------------------------------------------------------------
  --Logging global variables
  g_log_fdir  VARCHAR2(50):='LOGDIR';
  g_log_fname VARCHAR2(50):='zms_kjo_pick.log';
  g_log_fptr  utl_file.file_type;
/*********************************************************************/
/* PACKAGE BODY: kjo                                                 */
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
PROCEDURE p_kjo_scarce_resources_ctl(O_err_code OUT INTEGER) IS

   l_orig_wh    ZMS_KJO_DIV_EXTRACT.WH%TYPE;
   l_process_no ZMS_KJO_DIV_EXTRACT.ORD_QTY%TYPE;
   l_pick_wh    ZMS_KJO_DIV_EXTRACT.WH%TYPE;
   l_prev_wh    ZMS_KJO_DIV_EXTRACT.WH%TYPE;
   O_error_message  VARCHAR2(2000);
   scarce_resource_error EXCEPTION;

CURSOR c_get_wh_ctl IS
SELECT orig_wh, process_no, pick_wh, prev_wh
  FROM zms_kjo_wh_control pwc
 WHERE pwc.active_flag = 'Y'
 ORDER BY pwc.div, process_no;

BEGIN
   /******************************************************************/
   /******************************************************************/

     g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_kjo_scarce_resources_ctl started:'));

    FOR i_wh_ctl IN c_get_wh_ctl
    LOOP
        l_orig_wh   := i_wh_ctl.orig_wh;
        l_process_no:= i_wh_ctl.process_no;
        l_pick_wh   := i_wh_ctl.pick_wh;
        l_prev_wh   := i_wh_ctl.prev_wh;

       utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - SCARCE_RESOURCES - zms_kjo_wh_control Pick Ctl: Orig_WH: '|| l_orig_wh ||' - Process_No '|| l_process_no ||' - Pick_WH '|| l_pick_wh ||' - Prev_WH '|| NVL(l_prev_wh,0)));
       utl_file.fflush(g_log_fptr);
       p_kjo_alloc_scarce_resources(l_orig_wh, l_process_no, l_pick_wh, l_prev_wh, O_err_code);

       IF O_err_code != 0 THEN
          RAISE SCARCE_RESOURCE_ERROR;
       END IF;

    END LOOP;

    --COMMIT;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_kjo_scarce_resources_ctl done:'));
     utl_file.put_line(g_log_fptr,'====================================================================');
     utl_file.fflush(g_log_fptr);
     utl_file.fclose(g_log_fptr);

EXCEPTION

   WHEN SCARCE_RESOURCE_ERROR THEN
        O_error_message := SQLERRM || ' problem in p_kjo_scarce_resources_ctl';
        O_err_code := 20101;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_kjo_scarce_resources_ctl';
        O_err_code := 20101;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

END p_kjo_scarce_resources_ctl;
/*********************************************************************/
/* LOCAL PROCEDURE: p_kjo_alloc_scarce_resources                     */
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
/*       stores) 
/*********************************************************************/
PROCEDURE p_kjo_alloc_scarce_resources (l_ctl_orig_wh    IN NUMBER,
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
   m_dist_qty st_dist_qty;
   m_rowid st_rowid;

   i BINARY_INTEGER := 0;
   j BINARY_INTEGER := 0;
   l_loop NUMBER := 1;
   tot_stores  NUMBER;

  CURSOR c_skus IS
  SELECT kjo.sku,
         SUM(kjo.ord_qty) req_qty,
         COUNT(*) tot_num,
         kjo.wh
    FROM ZMS_KJO_DIV_EXTRACT kjo
   WHERE kjo.wh      = l_ctl_pick_wh
     AND kjo.orig_wh = l_ctl_orig_wh
     AND kjo.repl_sku_group = -1
   GROUP BY kjo.SKU, kjo.WH;

   CURSOR c_max_available IS
--sa   SELECT NVL(a.stock_avail,0) , NVL(b.st_pack_size,1)
   SELECT NVL(a.stock_avail,0) , NVL(b.inner_pack_size,1)
     FROM zms_KJO_WIN_WH a, item_supp_country b
    WHERE a.WH  = l_wh        
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
 
   CURSOR c_single_sku IS
   SELECT z.STORE,
          z.SKU,
          z.REQ,
          z.WH,
          CASE WHEN z.stock_on_hand <= 0 THEN 'A' ELSE 'B' END out_of_stock,
          z.ord_qty,
          z.ROWID myrow,NVL(zdt.fill_to_model,'N') fill_to_model
   FROM ZMS_KJO_DIV_EXTRACT z,
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
   FROM ZMS_KJO_DIV_EXTRACT z,
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
      Akron. Insert Records for Next WH Run
      ***************************************************************/

     g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
     fptr := utl_file.fopen(g_log_fdir,'zms_kjo_pick_scarce_sku.log','A');

      IF NVL(l_ctl_prev_wh,0) <> 0 THEN

         INSERT INTO ZMS_KJO_DIV_EXTRACT
            (store, sku, req, po_line_nbr, po_type, division, ord_qty, store_priority, in_str_date,
             priority, repl_sku_group, watch_priority, dist_type, wh, request_sku, stock_on_hand,
             stock_avail, move_order_id, alloc_id, distro_date, cust_name, orig_wh, orig_ord_qty,
             orig_req, orig_po_type, pick_process_nbr)
         SELECT kjo.store, sku, kjo.req, po_line_nbr, po_type, division, orig_ord_qty - ord_qty ord_qty, store_priority, in_str_date,
                priority, repl_sku_group, watch_priority, dist_type, l_ctl_pick_wh, kjo.request_sku, stock_on_hand + ord_qty,
                stock_avail, move_order_id, alloc_id, distro_date, cust_name, orig_wh, orig_ord_qty - ord_qty orig_ord_qty,
                kjo.req, po_type, 0 pick_process_nbr
           FROM ZMS_KJO_DIV_EXTRACT kjo
          WHERE kjo.orig_ord_qty - kjo.ord_qty > 0
            AND kjo.orig_wh        = l_ctl_orig_wh
            AND kjo.wh             = l_ctl_prev_wh
            AND kjo.repl_sku_group = -1;

        utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - Create Next WH DIV Extract - '||l_ctl_pick_wh||' - '||SQL%ROWCOUNT));

        --COMMIT;

        INSERT INTO ZMS_KJO_DIV_EXTRACT_bk
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
           FROM ZMS_KJO_DIV_EXTRACT kjo
          WHERE kjo.wh  = l_ctl_pick_wh
            AND kjo.wh <> orig_wh
            AND kjo.repl_sku_group = -1;

        utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - Backup Process_Type 5: '||l_ctl_pick_wh||'  '||SQL%ROWCOUNT));

        --COMMIT;

     END IF;

     -- Set ord_qty = 0 and pick_process_nbr = 1 when the warehouse is not scheduled to pick
     UPDATE ZMS_KJO_DIV_EXTRACT kjo
        SET kjo.ord_qty          = 0,
            kjo.pick_process_nbr = 1
      WHERE kjo.wh              = l_ctl_pick_wh
        AND kjo.orig_wh         = l_ctl_orig_wh
        AND kjo.repl_sku_group  = -1
        AND kjo.wh NOT IN (SELECT DISTINCT wh FROM zms_kjo_pick_day_stores)
        AND kjo.wh NOT IN (SELECT DISTINCT wh FROM zms_zpf_sku_PICK_DAY_STORES) 
        ;  

     --COMMIT;

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
 
        CLOSE c_max_available;
        IF l_max_available >= l_pack_size THEN        -- J.P. 102006
            l_max_available := l_max_available - MOD(l_max_available,l_pack_size);
        ELSE
            l_max_available := 0;
        END IF;
 
      /***************************************************************/
      /* IF (there is no stock at the warehouse) then                */
      /*    delete all records with that sku since we can't pick     */
      /*    what we don't have                                       */
      /***************************************************************/
        IF (l_max_available = 0) THEN

        --Akron - Keep records for next CTL Loop
           UPDATE ZMS_KJO_DIV_EXTRACT kjo
              SET kjo.ord_qty          = 0,
                  kjo.pick_process_nbr = 1
            WHERE kjo.SKU     = l_sku
              AND kjo.wh      = l_ctl_pick_wh
              AND kjo.orig_wh = l_ctl_orig_wh; 
 
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
 
                 UPDATE ZMS_KJO_DIV_EXTRACT
                    SET ord_qty          = 0,
                        pick_process_nbr = 1
                  WHERE ROWID = l_single_sku.myrow;
 
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
                  UPDATE ZMS_KJO_DIV_EXTRACT
                     SET ord_qty          = (l_max_available - l_current_dist_qty),
                         stock_avail      = (l_max_available - l_current_dist_qty),
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
  
                  IF (l_max_available - l_current_dist_qty) >= (l_nofill_sku.ord_qty - m_dist_qty(j)) THEN
                   l_current_dist_qty := l_current_dist_qty + (l_nofill_sku.ord_qty - m_dist_qty(j));
                   m_dist_qty(j) := m_dist_qty(j) + (l_nofill_sku.ord_qty - m_dist_qty(j));
                  ELSE
                   m_dist_qty(j) := m_dist_qty(j) + (l_max_available - l_current_dist_qty);
                   l_current_dist_qty := l_current_dist_qty + (l_max_available  - l_current_dist_qty); 

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
 
           IF l_current_dist_qty >= l_max_available THEN
            l_loop := 0;
           END IF;
         END LOOP; -- l_loop
         j := 0;
         FOR j IN 1..i
         LOOP
           UPDATE ZMS_KJO_DIV_EXTRACT
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
        UPDATE zms_KJO_WIN_WH
           SET STOCK_AVAIL = NVL(STOCK_AVAIL,0)- l_current_dist_qty
         WHERE WH  = l_wh   
           AND SKU = l_sku;

        l_current_dist_qty := 0;

        UPDATE ZMS_KJO_DIV_EXTRACT kjo
           SET pick_process_nbr  = 1
          WHERE kjo.sku          = l_sku
            AND kjo.wh           = l_ctl_pick_wh
            AND kjo.orig_wh      = l_ctl_orig_wh
            AND kjo.pick_process_nbr    <> 1
            AND kjo.repl_sku_group       = -1;

     END LOOP; -- l_skus
     utl_file.putf(fptr,'I am Done!! ,bye\n');
     utl_file.fflush(fptr);
     utl_file.fclose(fptr);
     utl_file.put_line(g_log_fptr,'====================================================================');
 

EXCEPTION

   WHEN OTHERS THEN
        O_error_message := SQLERRM || ' problem in p_kjo_scarce_resources';
        O_err_code := 20102;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);

END p_kjo_alloc_scarce_resources;
   
/**************************************************************************/
/* PUBLIC PROCEDURE : p_kjo_alloc_sku_groups
   Function         : It will allocate scarce resources among the sku groups.
   The priority will be the same as before. Only thing that has been
   changed is that it will consider whetherto fill to model immediately or
   not*/
  -- 05/20/2026 - Hari  - Added wh list from zms_zpf_sku_PICK_DAY_STORES
/**************************************************************************/
PROCEDURE p_kjo_alloc_sku_groups (p_is_forecast IN BOOLEAN,
                                  O_err_code   OUT INTEGER) IS
   l_req               ALLOC_HEADER.ALLOC_NO%TYPE;
--   l_req               REQDETAIL.REQ%TYPE;
   l_req               ZMS_KJO_DIV_EXTRACT.REQ%TYPE;
   l_sku               ZMS_KJO_DIV_EXTRACT.SKU%TYPE;
   l_division          ZMS_KJO_DIV_EXTRACT.DIVISION%TYPE;
   l_wh                WH.WH%TYPE;
   l_nopick_sku        ZMS_KJO_NOPICK_REPORT.SKU%TYPE;
   l_nopick_retail     ZMS_KJO_NOPICK_REPORT.UNIT_RETAIL%TYPE;
   l_nopick_cost       ZMS_KJO_NOPICK_REPORT.UNIT_COST%TYPE;
   l_stock_avail       zms_KJO_WIN_WH.STOCK_AVAIL%TYPE;
   l_repl_orig_wh      WH.WH%TYPE;
   l_repl_sku_group    ZMS_KJO_DIV_EXTRACT.REPL_SKU_GROUP%TYPE;
   l_ord_qty           ZMS_KJO_DIV_EXTRACT.ORD_QTY%TYPE;
   l_repl_sku          SUB_ITEMS_HEAD.ITEM%TYPE;
--sa   l_repl_sku          ZALE_REPL_SKU_GROUP_DETAIL.SKU%TYPE;
   l_lp_num            NUMBER := 0; /* Represents the priority */
   l_new_qty           NUMBER;
   l_close_loop        NUMBER;
   l_count             NUMBER := 0;
   l_no_repl_sku_group NUMBER := -1;
   l_current_pick_qty  ZMS_KJO_NOPICK_REPORT.PICK_QTY%TYPE;
   l_store             ZMS_KJO_DIV_EXTRACT.STORE%TYPE;
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
      SELECT wc.process_no, kjo.orig_wh, kjo.repl_sku_group, SUM(NVL(kjo.ord_qty,0)) req_qty
        FROM ZMS_KJO_DIV_EXTRACT kjo, zms_kjo_wh_control wc
       WHERE kjo.sku     = -1
         AND kjo.orig_wh = wc.orig_wh
         AND kjo.orig_wh = wc.pick_wh
       GROUP BY wc.process_no, kjo.orig_wh, kjo.repl_sku_group
       ORDER BY wc.process_no, kjo.orig_wh, kjo.repl_sku_group;

/*The following cursor is used to determine the total stock at sku level
    for each replenishment sku group */

     CURSOR c_get_stock_matrix IS
     SELECT wwz.sku,
            wwz.stock_avail stock,
            zwc.pick_wh wh,
            NVL(isc.inner_pack_size,1) inner_pack_size
      FROM zms_KJO_WIN_WH wwz, ITEM_SUPP_COUNTRY isc,
           zms_kjo_wh_control zwc, zms_kjo_main_sub zms
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
        AND zwc.pick_wh IN (SELECT wh FROM zms_kjo_pick_day_stores union SELECT DISTINCT wh FROM zms_zpf_sku_PICK_DAY_STORES)
      ORDER BY zwc.process_no, zms.item_pick_priority; 
 

   CURSOR c_get_kjo_div_extract_repl IS
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
   FROM ZMS_KJO_DIV_EXTRACT z,
        (SELECT DISTINCT item FROM SUB_ITEMS_HEAD) sih,
        ZMS_ZALE_DIST_TYPE zdt
   WHERE z.SKU   = -1
     AND z.repl_sku_group = sih.item
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
      ZMS_KJO_DIV_EXTRACT.ORD_QTY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_store IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.STORE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_req IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.REQ%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_po_line_nbr IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.PO_LINE_NBR%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_po_type IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.PO_TYPE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_in_str_date IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.IN_STR_DATE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_distro_date IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.DISTRO_DATE%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_cust_name IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.CUST_NAME%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_priority IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.PRIORITY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_store_priority IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.STORE_PRIORITY%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_division IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.DIVISION%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_wh IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.WH%TYPE
      INDEX BY BINARY_INTEGER;

      TYPE st_watch_priority IS TABLE OF
        ZMS_KJO_DIV_EXTRACT.WATCH_PRIORITY%TYPE
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
fptr := utl_file.fopen(g_log_fdir,'zms_kjo_pick_sku_groups.log','W');

utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_kjo_alloc_sku_groups started:'));

      SELECT COUNT(*) INTO l_count
        FROM ZMS_KJO_DIV_EXTRACT
       WHERE SKU = -1;

--   utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -     l_count: '||l_count||' '));

   IF l_count = 0 THEN
      utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -     No SKU Groups'));
      RAISE no_sku_groups;
   END IF;

-- fptr := utl_file.fopen('ZSEND','zms_kjo_pick_scarce_sg','w');
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
    FOR l_get_kjo_div_extract_repl IN c_get_kjo_div_extract_repl
    LOOP

     --utl_file.put_line(g_log_fptr, '4');
     --utl_file.fflush(g_log_fptr);

     l_repl_cnt := l_repl_cnt +1;
     IF l_repl_start_cnt = 0 THEN
     l_repl_start_cnt := l_repl_cnt;
     END IF;

     mt_req(l_repl_cnt)         := l_get_kjo_div_extract_repl.REQ;
     mt_sku1(l_repl_cnt)        := l_get_kjo_div_extract_repl.SKU;
     mt_ord_qty(l_repl_cnt)     := l_get_kjo_div_extract_repl.ord_qty;
     mt_distro_qty(l_repl_cnt)  := 0;
     mt_repl_skgp1(l_repl_cnt)  := l_get_kjo_div_extract_repl.repl_sku_group;
     mt_store(l_repl_cnt)       := l_get_kjo_div_extract_repl.STORE;
     mt_po_line_nbr(l_repl_cnt) := l_get_kjo_div_extract_repl.po_line_nbr;
     mt_po_type(l_repl_cnt)     := l_get_kjo_div_extract_repl.po_type;
     mt_stock_on_hand(l_repl_cnt) := l_get_kjo_div_extract_repl.stock_on_hand;
     mt_dist_type(l_repl_cnt)   := l_get_kjo_div_extract_repl.dist_type;
     mt_division(l_repl_cnt)    := l_get_kjo_div_extract_repl.DIVISION;
     mt_wh1(l_repl_cnt)         := l_get_kjo_div_extract_repl.WH;
     mt_store_priority(l_repl_cnt)    := l_get_kjo_div_extract_repl.store_priority;
     mt_in_str_date(l_repl_cnt) := l_get_kjo_div_extract_repl.in_str_date;
     mt_distro_date(l_repl_cnt) := l_get_kjo_div_extract_repl.distro_date;
     mt_cust_name(l_repl_cnt)   := l_get_kjo_div_extract_repl.cust_name;
     mt_priority(l_repl_cnt)    := l_get_kjo_div_extract_repl.priority;
     mt_watch_priority(l_repl_cnt) := l_get_kjo_div_extract_repl.watch_priority;
     mt_fill_to_model(l_repl_cnt)  := l_get_kjo_div_extract_repl.ftm;
     mt_orig_wh(l_repl_cnt)        := l_get_kjo_div_extract_repl.orig_wh;
     mt_orig_req(l_repl_cnt)       := l_get_kjo_div_extract_repl.orig_req;
     mt_orig_po_type(l_repl_cnt)   := l_get_kjo_div_extract_repl.orig_po_type;
     mt_orig_ord_qty(l_repl_cnt)   := l_get_kjo_div_extract_repl.orig_ord_qty;
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

   DELETE FROM ZMS_KJO_DIV_EXTRACT
    WHERE repl_sku_group = l_repl_sku_group
      AND orig_wh        = l_repl_orig_wh
      AND SKU = -1;

   --utl_file.put_line(g_log_fptr, '11 - '|| l_repl_cnt);
   --utl_file.fflush(g_log_fptr);

   FOR I IN 1..l_repl_cnt
   LOOP
     --utl_file.put_line(g_log_fptr, '12 - '|| l_repl_cnt);
     --utl_file.fflush(g_log_fptr);

     INSERT INTO ZMS_KJO_DIV_EXTRACT
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
   /* Decrement the Stock in Sku from zms_KJO_WIN_WH */
   /*Initialize Stock Matrix */
   FOR I IN 1..l_stk_end
   LOOP
     UPDATE zms_KJO_WIN_WH
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
  DELETE FROM ZMS_KJO_DIV_EXTRACT
     WHERE  SKU = -1;
  IF (NOT  p_is_forecast ) THEN
 
        COMMIT;
/*      p_update_feedback_reqdetail;  */ /*will be called from proC*/
  END IF;/*End of NOT p_forecast */
  utl_file.putf(fptr,'I am Done!! ,bye\n');
  utl_file.fflush(fptr);
  utl_file.fclose(fptr);
 
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
        O_error_message := SQLERRM || ' problem in p_kjo_alloc_sku_groups';
        O_err_code := 20106;
        utl_file.put_line(g_log_fptr, O_error_message);
        utl_file.put_line(g_log_fptr, 'l_repl_orig_wh - '|| l_repl_orig_wh ||'  l_repl_sku_group - ' || NVL(l_repl_sku_group,-2) || '  mt_sku1(l_repl_cnt) - ' || NVL(mt_sku1(l_repl_cnt),-2) || '  mt_wh1(l_repl_cnt) - ' || NVL(mt_wh1(l_repl_cnt),-2));
        utl_file.fflush(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20106,SQLERRM);

END p_kjo_alloc_sku_groups;

/***************************************************************************
The following procedure will update the feedback reqdetail tables
*****************************************************************************/
PROCEDURE p_kjo_upd_feedback_reqdetail(O_err_code OUT INTEGER) IS

   O_error_message  VARCHAR2(2000);

BEGIN

g_log_fptr := utl_file.fopen(g_log_fdir, g_log_fname, 'A');
utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' - p_kjo_upd_feedback_reqdetail started:'));

/******************************************************************/
/* Create New Transfers for Akron and SJIL                        */
/* Update cancel_qty on Zale Transfers                            */
/******************************************************************/

    -- Everything should be allocated by now
     DELETE FROM ZMS_KJO_DIV_EXTRACT kjo
           WHERE kjo.ord_qty =  0
              OR kjo.SKU     = -1;

     EXECUTE IMMEDIATE 'truncate table zms_kjo_new_tsf_no drop storage';

     -- Assign new transfer numbers for records where orig_wh
     INSERT INTO zms_kjo_new_tsf_no
        (wh, store, req, cust_name)
        (SELECT wh, store, transfer_number_sequence.nextval new_req, cust_name
           FROM (SELECT DISTINCT wh, store, cust_name
                   FROM ZMS_KJO_DIV_EXTRACT
                  WHERE orig_wh <> wh));

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Create New TSF Numbers: '||SQL%ROWCOUNT));

     MERGE INTO ZMS_KJO_DIV_EXTRACT kjo USING
        (SELECT a.wh, a.store, a.orig_wh, a.sku, a.po_type,
                a.orig_req, a.orig_po_type, b.req, b.cust_name
           FROM ZMS_KJO_DIV_EXTRACT a, zms_kjo_new_tsf_no b
          WHERE a.wh        = b.wh
            AND a.store     = b.store
            AND NVL(a.cust_name,' ') = NVL(b.cust_name,' ')
            AND a.orig_wh <> a.wh) dt
     ON(kjo.wh = dt.wh and kjo.store = dt.store and kjo.orig_wh = dt.orig_wh and
        kjo.sku = dt.sku and kjo.orig_req = dt.orig_req and NVL(kjo.cust_name,' ') = NVL(dt.cust_name,' '))
     WHEN MATCHED THEN
     UPDATE
     SET kjo.req = dt.req;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Assign New TSF Numbers to kjo_div_extract: '||SQL%ROWCOUNT));

     INSERT INTO tsfhead
        (tsf_no, tsf_parent_no, from_loc_type, from_loc,
         to_loc_type, to_loc, exp_dc_date, dept, inventory_type, tsf_type,
         status, freight_code, routing_code, create_date,
         create_id, approval_date, approval_id, delivery_date,
         close_date, ext_ref_no, repl_tsf_approve_ind, comment_desc,
         exp_dc_eow_date, mrt_no, not_after_date, context_type,
         context_value, restock_pct, wf_need_date, delivery_slot_id, order_no)
     SELECT DISTINCT kjo.req tsf_no, NULL tsf_parent_no, 'W' from_loc_type, kjo.wh||'1001' from_loc,
         'S' to_loc_type, kjo.store to_loc, NULL exp_dc_date, NULL dept, 'A' inventory_type,
         'MR' tsf_type, 'L' status, 'N' freight_code, NULL routing_code, get_vdate create_date,
         'PICKGEN' create_id, get_vdate approval_date, 'PICKGEN' approval_id, get_vdate+2 delivery_date,
         NULL close_date, NULL ext_ref_no, 'N' repl_tsf_approve_ind,
         cust_name comment_desc, NULL exp_dc_eow_date, NULL mrt_no, NULL not_after_date, NULL context_type,
         NULL context_value, NULL restock_pct, NULL wf_need_date, NULL delivery_slot_id, NULL order_no
       FROM ZMS_KJO_DIV_EXTRACT kjo
      WHERE kjo.orig_wh <> kjo.wh
      ORDER BY kjo.wh||'1001', kjo.store;

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
       FROM (SELECT kjo.req, kjo.request_sku, SUM(kjo.ord_qty) ord_qty
               FROM ZMS_KJO_DIV_EXTRACT kjo
              WHERE kjo.orig_wh <> kjo.wh
              GROUP BY kjo.req, kjo.request_sku) a
      ORDER BY a.req, a.request_sku;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Create new tsfdetail where orig_wh <> wh: '||SQL%ROWCOUNT));
 
     -- Update tsf_reserve on item_loc_soh for New WH
     MERGE INTO item_loc_soh ils USING
        (SELECT TO_NUMBER(kjo.wh||'1001') wh, kjo.request_sku, SUM(NVL(kjo.ord_qty,0)) ord_qty
           FROM ZMS_KJO_DIV_EXTRACT kjo
          WHERE kjo.orig_wh <> kjo.wh
          GROUP BY kjo.wh, kjo.request_sku) dt
     ON(ils.loc = dt.wh and ils.item = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_reserved_qty = ils.tsf_reserved_qty + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsf_reserve on item_loc_soh for Akron WH: '||SQL%ROWCOUNT));

     -- Update tsf_resserve on item_loc_soh for Orig WH - Use tsf_qty due to inner_pack_size
     MERGE INTO item_loc_soh ils USING
        (SELECT TO_NUMBER(kjo.orig_wh||'1001') wh, kjo.request_sku, SUM(NVL(td.tsf_qty,0)) tsf_qty
           FROM ZMS_KJO_DIV_EXTRACT kjo, tsfdetail td
          WHERE kjo.orig_req    = td.tsf_no
            AND kjo.request_sku = td.item
            AND kjo.orig_wh    <> kjo.wh
          GROUP BY kjo.orig_wh, kjo.request_sku) dt
     ON(ils.loc = dt.wh and ils.item = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET ils.tsf_reserved_qty = NVL(ils.tsf_reserved_qty,0) - dt.tsf_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsf_reserve on item_loc_soh for Dallas WH: '||SQL%ROWCOUNT));

     -- Update cancelled_qty on original replenishment transfers
     MERGE INTO tsfdetail td USING
        (SELECT kjo.orig_req, kjo.request_sku, SUM(NVL(kjo.ord_qty,0)) ord_qty
           FROM ZMS_KJO_DIV_EXTRACT kjo
          WHERE kjo.orig_wh  <> kjo.wh
            AND kjo.orig_req <> kjo.req
            AND kjo.po_type   = 'T'
          GROUP BY kjo.orig_req, kjo.request_sku) dt
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
        (SELECT kjo.orig_req, kjo.store, SUM(NVL(kjo.ord_qty,0)) ord_qty
           FROM ZMS_KJO_DIV_EXTRACT kjo
          WHERE kjo.orig_wh     <> kjo.wh
            AND kjo.orig_req    <> kjo.req
            AND kjo.orig_po_type = 'A'
          GROUP BY kjo.orig_req, kjo.store) dt
     ON(ad.alloc_no = dt.orig_req and ad.to_loc = dt.store)
     WHEN MATCHED THEN
     UPDATE
     SET ad.qty_cancelled = NVL(ad.qty_cancelled,0) + dt.ord_qty,
         ad.qty_allocated = NVL(ad.qty_allocated,0) - dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update cancelled_qty on Dallas Allocations: '||SQL%ROWCOUNT));

     INSERT INTO zms_ifo_pick_div_extract
        (sku, wh, store, tsf_type, distro_type,
         ord_qty, req, division, request_sku, distro_date, cust_name, data_source)
        SELECT kjo.sku, kjo.wh, kjo.store, kjo.po_type tsf_type, DECODE(kjo.dist_type,'SO','SO','RP') dist_type,
               SUM(kjo.ord_qty), kjo.req, zal2.store_div division, kjo.request_sku, kjo.distro_date, kjo.cust_name, 'RMS' data_source
          FROM ZMS_KJO_DIV_EXTRACT kjo, zms_all_location zal1, zms_all_location zal2
         WHERE kjo.wh           = zal1.loc_four_digit
           AND kjo.store        = zal2.loc
           AND zal1.akron_wh_ind = 'Y'
         GROUP BY kjo.sku, kjo.wh, kjo.store, kjo.po_type, DECODE(kjo.dist_type,'SO','SO','RP'),
                  kjo.req, zal2.store_div, kjo.request_sku, kjo.distro_date, kjo.cust_name;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Insert Into zms_ifo_pick_div_extract table: '||SQL%ROWCOUNT));

 

/******************************************************************/
/* Update Initially Created Replenishment Transfers               */
/*                                                                */
/******************************************************************/


     MERGE INTO alloc_detail ad USING
     (SELECT kjo.req, kjo.store, kjo.po_type, SUM(kjo.ord_qty) ord_qty
        FROM ZMS_KJO_DIV_EXTRACT kjo
       WHERE kjo.po_type = 'A'
       GROUP BY kjo.req, kjo.store, kjo.po_type) dt
     ON(ad.alloc_no = dt.req AND
        ad.to_loc   = dt.store)
     WHEN MATCHED THEN
     UPDATE
     SET ad.qty_distro = NVL(ad.qty_distro,0) + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update Allocation qty_distro: '||SQL%ROWCOUNT));

     MERGE INTO tsfdetail td USING
     (SELECT kjo.req, kjo.request_sku, SUM(kjo.ord_qty) ord_qty
       FROM ZMS_KJO_DIV_EXTRACT kjo
      WHERE kjo.po_type = 'T'
        AND kjo.wh = kjo.orig_wh
      GROUP BY kjo.req, kjo.request_sku) dt
      ON(td.tsf_no = dt.req AND
         td.item   = dt.request_sku)
     WHEN MATCHED THEN
     UPDATE
     SET td.distro_qty = NVL(td.distro_qty,0) + dt.ord_qty;

     utl_file.put_line(g_log_fptr, (TO_CHAR(SYSDATE, 'hh24:mi:ss')||' -  Update tsfdetail distro_qty: '||SQL%ROWCOUNT));

     MERGE INTO tsfhead th USING
     (SELECT DISTINCT kjo.req, kjo.po_type
        FROM ZMS_KJO_DIV_EXTRACT kjo
       WHERE kjo.po_type = 'T'
         AND kjo.wh = kjo.orig_wh) dt
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
        O_error_message := SQLERRM || ' problem in p_kjo_upd_feedback_reqdetail';
        O_err_code := 20107;
        utl_file.put_line(g_log_fptr, (O_error_message));
        utl_file.fflush(g_log_fptr);
        utl_file.fclose(g_log_fptr);
        RAISE_APPLICATION_ERROR (-20106,SQLERRM);

END p_kjo_upd_feedback_reqdetail; 
  
END kjo;
/