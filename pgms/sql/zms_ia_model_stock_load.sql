-- *************************************************************
--
-- 05/26/2026  Hari   -- Code change RMS Model load process from IA for KJO data
SET SERVEROUTPUT ON SIZE 1000000
SET TIMING ON

SPOOL ${LOGDIR}/zms_ia_model_stock_load.log

WHENEVER SQLERROR EXIT FAILURE;
WHENEVER OSERROR  EXIT FAILURE;

 DECLARE

    INIT_LOG_FAIL       EXCEPTION;
    CLOSE_LOG_FAIL      EXCEPTION;
    ZERO_REC_LOAD 	EXCEPTION;	

    g_err_msg           VARCHAR2(500);
    g_debug_lvl         INTEGER := 1;
    c_program           CONSTANT VARCHAR2(30) := 'zms_ia_model_stock_load';
    
    l_rec_merged	number :=0;
    l_rec_inserted	number :=0;
    l_rec_updated	number :=0;
    l_sysdate 		date;
    l_vdate             date;
    l_vdate_char	varchar2(8);
    l_is_sunday		varchar2(1) := 'N';
    l_process_ind	varchar2(1) := 'N';
    l_process_id	number;
    l_last_process_id 	number;
    l_next_process_id   number;
    l_input_run_type    varchar2(10) := '&&1';
    l_database		varchar2(30);
    l_check_empty_file 	varchar2(1);
    l_file_load		varchar2(1) :='Y';
 
BEGIN

    IF (zlog.initialize(g_err_msg, c_program, 0, g_debug_lvl) = FALSE)
            THEN RAISE INIT_LOG_FAIL;
    END IF;
    dbms_output.put_line('1');
 
    zlog.write_log('Started');

	zlog.write_log(' Run time : '||l_input_run_type);
    
	select name into l_database from v$database;
  
	--------------------------------------------------
	-- truncate zms_model_stock_copy for nightly batch
	IF l_input_run_type = 'PM_RUN' then 
		zms_truncate_tab('zms_model_stock_copy');
	END IF;

	--------------------------------------------------- 
        select vdate l_vdate, sysdate l_sysdate, to_char(vdate,'MMDDYYYY') l_vdate_char, 
		decode(to_char(vdate,'DY'),'SUN','Y','N') l_is_sunday, 
		case when to_char(vdate,'DY') = 'SUN' then 'X'
		     when to_char(vdate,'DY') = 'SAT' then 'X' -- 4/12/2023 meeting 
		     when l_input_run_type = 'AM_RUN' then 'Z'
		else 'N' end l_process_ind,
		case when to_char(vdate,'DY') in('SUN','SAT') then 'N' else 'Y' end l_check_empty_file 
 	into l_vdate, l_sysdate, l_vdate_char, l_is_sunday, l_process_ind, l_check_empty_file
	from period;

	select nvl(max(process_id),10) last_process_Id, nvl(max(process_id),9) + 1 next_process_id 
	into l_last_process_id, l_process_id
	from zms_ifi_ia_model_stock;

	----------------------------------------------------
	-- load model stock from external file
	----------------------------------------------------
	insert into zms_ifi_ia_model_stock(insert_date, process_date, process_id, process_status, err_msg, 
		loc, sku, qty, ia_loc_num, rms_loc, rms_loc_div, dept, class, subclass,
		file_rec, file_name)
	select l_vdate insert_date, l_sysdate process_date, l_process_id process_id, 
		case when loc is null then 'E'
		     when loc like 'E%' then 'R' 
		     --when loc like 'A%' then 'X'   -- Code change to process kjo Data
			 else l_process_ind end process_status,
		case when loc is null then 'Missing location'
		     when loc like 'E%' then 'ECom Reserve'
		     --when loc like 'A%' then 'KJO location' -- Code change to process kjo Data
			when loc is not null and substr(loc,1,1) not in('E') and l_process_ind = 'X' then 'SKIP ALL'   -- Code change to process kjo Data
			when loc is not null and substr(loc,1,1) not in('E') and l_process_ind = 'Z' then 'File load after Replenishment run'  -- Code change to process kjo Data
		else null end err_msg, 
		loc, sku, qty, 
		case when loc like 'A%' then 1||lpad(regexp_replace( loc, '[^[:digit:]]', '' ),4,'0')
		else regexp_replace( loc, '[^[:digit:]]', '' ) end ia_loc_num,
		0 rms_loc, 0 rms_loc_div, 0 dept, 0 class, 0 subclass,
		file_rec, file_name
	from zms_ia_model_stock_ext ex;

	/*
	where not exists (select 1 from zms_ifi_ia_model_stock ms 
			where ms.process_id = l_process_id
			and ms.insert_date = l_vdate
			and ex.loc = ms.loc and ex.sku = ms.sku);
	*/

 	l_rec_inserted := sql%rowcount;
        zlog.write_msg(g_debug_lvl,l_rec_inserted||' inserted to zms_ifi_ia_model_stock');
        commit;

	-- HH 4/17/2025 Email if zero record load from file 
	IF l_rec_inserted = 0 and l_input_run_type = 'PM_RUN' and l_check_empty_file = 'Y' and l_file_load = 'Y'
	  THEN 
		
		zlog.write_msg(g_debug_lvl,' File has zero record loaded');

		pid_email_pkg.mail(
          		sender      => 'zmssupport <ITMerchandisingDallas@signetjewelers.com>'
          		,recipients => '"zms support"<ITMerchandisingDallas@signetjewelers.com>'
          		,subject    => l_database||'- IA Model Stock file has ZERO record loaded'
          		,message    => 'IA Model Stock file has zero record loaded to zms_ifi_ia_model_stock table. Batch run type : '||l_input_run_type);

		RAISE ZERO_REC_LOAD;

	END IF;

	-------------------------------------------------
	-- Load RMS location
	merge into zms_ifi_ia_model_stock bs using(
	select /*+ parallel(ms,10) */ ms.*, al.loc_type, 
		sm.initiated_brand, sm.dept sku_dept, sm.class sku_class, sm.subclass sku_subclass, 
		nvl(sm.main_sku, sm.sku) msku,
		case when al.loc_type = 'S' then al.loc
    		when al.loc_type = 'W' then to_number(al.loc||1001)
    		else 0 end new_rms_loc,
		al.store_div,
		case when al.zone_name_regular like '%Dotcom%'
			or al.loc_entity = 'ECOM' then 'R'
		     when al.loc_type = 'W' then 'X' 
		else ms.process_status end loc_ind
	from zms_ifi_ia_model_stock ms, zms_all_location al, pid_sku_master sm
	where insert_date = l_vdate
	and process_id = l_process_id
	and ms.ia_loc_num = al.loc
	and ms.sku = sm.sku
	-- and case when ms.loc like 'A' then 1||rpad(substr(ms.loc,3),4,0) 
	--	when ms.loc like 'E%' then '0' else substr(ms.loc,3) end = to_char(al.loc)
	) dt
	on(bs.insert_date = dt.insert_date
	and bs.process_id = dt.process_id
	and bs.loc = dt.loc
	and bs.sku = dt.sku)
	when matched then update set bs.rms_loc = dt.new_rms_loc,
		bs.process_status = case when dt.loc_ind in('R','X') then dt.loc_ind
					when dt.loc_type = 'W' then 'X'
					when dt.new_rms_loc = 0 then 'E'
					else bs.process_status end,
		bs.err_msg = case when dt.loc_ind = 'R' then 'ECom reserve'
				when dt.loc_ind = 'W' then 'SKIP warehouse record'
				when dt.new_rms_loc = 0 then 'Invalid location'
				else null end,
		bs.rms_loc_div = dt.store_div,
		bs.sku_div = dt.initiated_brand,
		bs.dept = dt.sku_dept,
		bs.class = dt.sku_class,
		bs.subclass = dt.sku_subclass,
		bs.main_sku = dt.msku;

	l_rec_merged := sql%rowcount;
        zlog.write_msg(g_debug_lvl,l_rec_merged||' Load RMS location');
	commit;

		 ----------------------------------------------------
                -- exclude ECom location
                update zms_ifi_ia_model_stock ms
                set process_status = 'R',
                        err_msg = 'ECom location for reserve'
                where insert_date = l_vdate
		and process_id = l_process_id
                -- and process_status = 'N'
                and rms_loc in(select loc from zms_all_location
                                where zone_name_regular like '%Dotcom%'
				or lv1_name like '%.COM%');

                -- l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,sql%rowcount||' Flag ECom location for reserve');
                commit;

	----------------------------------------------------
        --DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_IFI_IA_MODEL_STOCK');
        --zlog.write_msg(g_debug_lvl,'Analyzed ZMS_IFI_IA_MODEL_STOCK');

	---------------------------------------------------
        -- Validation if NOT on Sunday night Monday morning and data load at night bf replen run

        IF l_is_sunday = 'N' and  l_input_run_type = 'PM_RUN' and l_rec_merged > 0 THEN

		----------------------------------------------------------------------
		-- truncate working table
		zms_truncate_tab('zms_model_stock_copy');
		zlog.write_msg(g_debug_lvl,' Truncate working table zms_model_stock_copy');

		----------------------------------------------------------------------
		-- 
		update zms_ifi_ia_model_stock ms
		set process_status = 'E', err_msg = 'Model stock quantity exceed limit'
		where insert_date = l_vdate
		and process_id = l_process_id
                and process_status = 'N'
		and qty > 1000;

		l_rec_updated := sql%rowcount;
		zlog.write_msg(g_debug_lvl,l_rec_updated||' Model stock quantity exceed limit');
		commit;
       
        	----------------------------------------------------
		--
		update zms_ifi_ia_model_stock ms
		set process_status = 'E', err_msg = 'Item not in item_master table'
		-- select * from zms_ifi_ia_model_stock ms
		where insert_date = l_vdate
		and process_id = l_process_id
		and process_status = 'N' 
		and to_char(sku) not in(select item from item_master);

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' Invalid Item - not in item_master table');
        	commit;

        	----------------------------------------------------
		--
		update zms_ifi_ia_model_stock ms
		set process_status = 'E', err_msg = 'SKU is not Main SKU'
		-- select * from zms_ifi_ia_model_stock ms
		where insert_date = l_vdate
		and process_id = l_process_id
		and process_status = 'N'
		and ms.sku in(select sku
				from zms_mainsub
				where mainsku <> sku);
		
		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' SKU is not Main SKU');
                commit;

		------------------------------------------
		update zms_ifi_ia_model_stock ms
		set process_status = 'E', err_msg = 'SKU is not Main SKU' 
		-- select * from zms_ifi_ia_model_stock ms
		where insert_date = l_vdate 
		and process_id = l_process_id
		and process_status = 'N'
		and ms.sku <> ms.main_sku; 

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' SKU is not Main SKU');
        	commit;

		----------------------------------------------------
                --
	 	update zms_ifi_ia_model_stock ms
		set process_status = 'K',
                        err_msg = 'SKU hierarchy not activate'
		where insert_date = l_vdate
		and process_id = l_process_id
		and process_status = 'N'
		and not exists (select 1 from zms_ia_activate_parms iap
				where ms.sku_div = iap.div
				and case when iap.dept > 0 then ms.dept else 0 end = iap.dept 
				and case when iap.class > 0 then ms.class else 0 end = iap.class
				and case when iap.subclass > 0 then ms.subclass else 0 end = iap.subclass
				and iap.active_ind = 'Y' -- comment if testing
				and iap.model_stock_ind='Y' --Added by Sagar on 12-Aug-25
				and iap.div in(10,40,60,150,20,80,90,170)
				);

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' SKU hierarchy not activate');
		commit;

		----------------------------------------------------
                --HH TEMP
		update zms_ifi_ia_model_stock ms
		set process_status = 'E',
			err_msg = 'Location not activate'
		where insert_date = l_vdate
		and process_id = l_process_id
                and process_status = 'N'
		and rms_loc_div not in(select div from zms_ia_activate_parms
					where active_ind = 'Y'
					and model_stock_ind='Y' --Added by Sagar on 12-Aug-25
					and div in(10,40,60,150,20,80,90,170));

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' Location not activate');
		commit;	
		
		----------------------------------------------------
		-- match model stock quantity -- set to skip process
		update zms_ifi_ia_model_stock ms 
		set process_status = 'M',
			err_msg = 'Model Stock quantity not change'
		where  process_status = 'N'
		and insert_date = l_vdate
		and process_id = l_process_id
		and exists (select /*+ parallel(il,10) */ 1 from repl_item_loc il
				where to_char(ms.sku) = il.item
				and ms.rms_loc = il.location
				and ms.qty = il.max_stock
                                and il.status = 'A'); -- mts 9/13/2024

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' Model stock quantity not change');
		commit;

		----------------------------------------------------
		-- set item loc with zero quantity
		/*
                update zms_ifi_ia_model_stock
		set process_status = 'D',
			err_msg = ' Deactivate from repl_item_loc'
		 where insert_date = l_vdate
                and process_id = l_process_id
                and process_status = 'N'
		and qty = 0;
		
		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' Deactivate from repl_item_loc');
		commit;
		*/
		---------------------------------------------------=
		-- load to working table
		insert into zms_model_stock_copy(item, rms_loc,qty, process_ind)
		select sku, rms_loc, qty, decode(qty,0,'D','A') process_ind
		from zms_ifi_ia_model_stock
		where insert_date = l_vdate
                and process_id = l_process_id
                and process_status = 'N';

		-- HH TEMPORARY LOAD FOR TESTING IN PROD
		/*and rms_loc in(2922,2663,2691,2727,2907,2852,2740,2668,2692,2915,
				2745,2715,2737,2804,2891,2824,2719,2913,2718,2918)
		and dept in(101,104,111);
		*/

		l_rec_updated := sql%rowcount;
                zlog.write_msg(g_debug_lvl,l_rec_updated||' Insert into working table zms_model_stock_copy');
		commit;
	
		--------------------------------------------------------
		-- flag process to update model stock
		/*
		merge into zms_model_stock_copy bs using(
		select /*+ parellel(il,10) */  
		/*	sc.item, sc.rms_loc
		from zms_model_stock_copy sc, repl_item_loc il
		where sc.item = il.item
		and sc.rms_loc = il.location
		and sc.process_ind = 'A'
		and sc.qty != il.max_stock
		) dt
		on (bs.item = dt.item and bs.rms_loc = dt.rms_loc)
		when matched then update set bs.process_ind = 'U';
		*/
		---------------------------------------------------- 
		zlog.write_msg(g_debug_lvl,' Analyze working table zms_model_stock_copy');

  		DBMS_STATS.GATHER_TABLE_STATS (ownname=>'ZMS',tabname=>'ZMS_MODEL_STOCK_COPY');
   		zlog.write_msg(g_debug_lvl,'Analyzed ZMS_MODEL_STOCK_COPY');

 	END IF; 

    -- Successful End

    zlog.write_log('Successfully Completed');

  -- Close logs
 
  IF      (zlog.close_all_logs(g_err_msg, FALSE) = FALSE)
        THEN RAISE CLOSE_LOG_FAIL;
  END IF;

-- Exception Handling

EXCEPTION

WHEN ZERO_REC_LOAD
	THEN
	dbms_output.put_line('ERROR:  Zero record load to zms_ifi_ia_model_stock');
	RAISE;

WHEN INIT_LOG_FAIL
        THEN
        dbms_output.put_line('ERROR:  Failed to init logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN CLOSE_LOG_FAIL
        THEN
        dbms_output.put_line('ERROR:  Failed to close logs, ERRMSG=' || g_err_msg);
        RAISE;

WHEN OTHERS
        THEN
        zlog.write_error('ERROR:  Failed for some other unknown reason ' || substr(sqlerrm,1,200));
        RAISE;

END;
/
SPOOL OFF;
EXIT
