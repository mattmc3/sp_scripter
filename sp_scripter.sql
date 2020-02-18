-- use master
-- go
if objectproperty(object_id('dbo.sp_scripter'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_scripter as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_scripter
-- author   : mattmc3
-- version  : v0.0.2
-- homepage : https://github.com/mattmc3/sp_scripter
-- license  : MIT - https://github.com/mattmc3/sp_scripter/blob/master/LICENSE
-- notes    :
-- * To increment version: `bumpversion --allow-dirty revision`
--------------------------------------------------------------------------------
alter procedure dbo.sp_scripter
    @object_type nvarchar(128)              -- What type of object to script
    ,@object_name nvarchar(128) = null      -- What to object to script if you only want one
    ,@include_drops bit = 0                 -- Include drops statements if possible
    ,@include_creates bit = 1               -- Include create statements
    ,@include_scriptdate bit = 1            -- Boolean for including timestamps in the script output
    ,@scriptdate_override datetime2 = null  -- Override the generated script date
    ,@indent nvarchar(8) = null             -- tabs or spaces: you choose. Default to 4 spaces
as
begin

--------------------------------------------------------------------------------
-- #region debug

-- when debugging, no need to use the proc, just uncomment this to declare the
-- proc params as variables and run piecemeal
--declare @object_type nvarchar(128) = 'alerts'   -- What to script
--      , @include_drops bit = 0                 -- Include drops statements if possible
--      , @include_creates bit = 1               -- Include create statements
--      , @include_scriptdate bit = 1            -- Boolean for including timestamps in the script output
--      , @scriptdate_override datetime2 = null  -- Override the generated script date
--      , @indent nvarchar(8) = null             -- tabs or spaces: you choose. Default to 4 spaces

-- #endregion debug
--------------------------------------------------------------------------------
-- #region setup

set nocount on

-- parameter defaults
select @indent = isnull(@indent, replicate(' ', 4))

-- constants
declare @APOS nvarchar(1) = N''''
      , @NL nvarchar(1) = char(10)
declare @APOS2 nvarchar(2) = @APOS + @APOS

-- variables
declare @now datetime2 = isnull(@scriptdate_override, getdate())
declare @strnow nvarchar(50) = format(@now, 'M/d/yyyy h:mm:ss tt')
      , @indent2 nvarchar(16) = replicate(@indent, 2)

-- make helper table of 100 numbers (0-99)
declare @numbers table (num int)
;with numbers as (
    select 0 as num
    union all
    select num + 1
    from numbers
    where num + 1 <= 99
)
insert into @numbers
select num
from numbers n
option (maxrecursion 100)

-- result
if object_id('tempdb..#result') is not null drop table #result
create table #result (
    row_id int identity(1, 1) not null
    ,obj_type nvarchar(128)
    ,obj_id bigint
    ,obj_guid uniqueidentifier
    ,obj_schema nvarchar(128)
    ,obj_name nvarchar(128)
    ,script_part nvarchar(256)
    ,script_ord bigint not null
    ,script nvarchar(max) not null
)

-- #endregion setup
--------------------------------------------------------------------------------
-- #region alerts, jobs, operators

if @object_type in ('alerts', 'jobs', 'operators') begin

    -- make a table to help assemble the results
    if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
    create table #sql_parts (
        obj_id bigint
        ,obj_guid uniqueidentifier
        ,obj_name nvarchar(512)
        ,script_part nvarchar(128)
        ,script_ord bigint
        ,script_ord2 bigint
        ,script nvarchar(max)
    )

    -- populate sql_parts for alerts
    if @object_type = 'alerts' begin
        ;with alerts as (
            select xsa.*
                 , xsc.name as category_name
            from msdb.dbo.sysalerts xsa
            left join msdb.dbo.syscategories xsc
              on xsa.category_id = xsc.category_id
           where xsa.name = isnull(@object_name, xsa.name)
        )
        insert into #sql_parts (obj_id, obj_name, script_part, script)
        select a.id
             , a.name
             , N'sp_add_alert' as script_part
             , N'/****** Object:  Alert [' + replace(a.name, @APOS, @APOS2) + N']' + case when @include_scriptdate = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
               N'EXEC msdb.dbo.sp_add_alert @name=N''' + replace(a.name, @APOS, @APOS2) + @APOS +
               case when a.message_id                is null then '' else N',' + @NL + @indent2 + '@message_id='                   + cast(a.message_id as nvarchar) end +
               case when a.severity                  is null then '' else N',' + @NL + @indent2 + '@severity='                     + cast(a.severity as nvarchar) end +
               case when a.enabled                   is null then '' else N',' + @NL + @indent2 + '@enabled='                      + cast(a.enabled as nvarchar) end +
               case when a.delay_between_responses   is null then '' else N',' + @NL + @indent2 + '@delay_between_responses='      + cast(a.delay_between_responses as nvarchar) end +
               case when a.include_event_description is null then '' else N',' + @NL + @indent2 + '@include_event_description_in=' + cast(a.include_event_description as nvarchar) end +
               case when a.category_name             is null then '' else N',' + @NL + @indent2 + '@category_name=N'''             + a.category_name + @APOS end +
               case when a.job_id                    is null then '' else N',' + @NL + @indent2 + '@job_id=N'''                    + lower(cast(a.job_id as nvarchar(128))) + @APOS end +
               @NL + N'GO' + @NL as script
        from alerts as a
    end

    -- populate sql_parts for jobs
    else if @object_type = 'jobs' begin

        -- SQL that appears once per job
        ;with jobs as (
            select sj.*
                 , sj.name as job_name
                 , suser_sname(sj.owner_sid) as owner_login_name
                 , sc.name as category_name
                 , sc.category_class
                 , sc.category_type
                 , so_email.name as notify_email_operator_name
                 , so_pager.name as notify_page_operator_name
                 , so_netsend.name as notify_netsend_operator_name
              from msdb.dbo.sysjobs sj
              join msdb.dbo.syscategories sc
                on sj.category_id = sc.category_id
              left join msdb.dbo.sysoperators so_email
                on sj.notify_email_operator_id = so_email.id
              left join msdb.dbo.sysoperators so_pager
                on sj.notify_page_operator_id = so_pager.id
              left join msdb.dbo.sysoperators so_netsend
                on sj.notify_netsend_operator_id = so_netsend.id
             where sj.name = isnull(@object_name, sj.name)
        )
        insert into #sql_parts (obj_guid, obj_name, script_part, script_ord, script)
        select j.job_id
             , j.job_name
             , N'header' as script_part
             , 1 as script_ord
             , N'/****** Object:  Job [' + replace(j.job_name, @APOS, @APOS2) + N']' + case when @include_scriptdate = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
               N'BEGIN TRANSACTION' + @NL +
               N'DECLARE @ReturnCode INT' + @NL +
               N'SELECT @ReturnCode = 0'
        from jobs as j
        union all
        select j.job_id
             , j.job_name
             , N'sp_add_category' as script_part
             , 2 as script_ord
             , N'/****** Object:  JobCategory [' + replace(j.category_name, @APOS, @APOS2) + N']    Script Date: ' + @strnow + N' ******/' + @NL +
               N'IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N''' + replace(j.category_name, @APOS, @APOS2) + ''' AND category_class=' + cast(j.category_class as nvarchar) + N')' + @NL +
               N'BEGIN' + @NL +
               N'EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N''JOB'', @type=N''LOCAL'', @name=N''' + replace(j.category_name, @APOS, @APOS2) + @APOS + @NL +
               N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' + @NL + @NL +
               N'END' + @NL
        from jobs as j
        union all
        select j.job_id
             , j.job_name
             , N'sp_add_job' as script_part
             , 3 as script_ord
             , N'DECLARE @jobId BINARY(16)' +
               @NL + N'EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N''' + replace(j.name, @APOS, @APOS2) + N'''' +
               case when j.enabled                      is null then N'' else N', ' + @NL + @indent2 + N'@enabled=' + cast(j.enabled as nvarchar) end +
               case when j.notify_level_eventlog        is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_eventlog='           + cast(j.notify_level_eventlog as nvarchar) end +
               case when j.notify_level_email           is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_email='              + cast(j.notify_level_email as nvarchar) end +
               case when j.notify_level_netsend         is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_netsend='            + cast(j.notify_level_netsend as nvarchar) end +
               case when j.notify_level_page            is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_page='               + cast(j.notify_level_page as nvarchar) end +
               case when j.delete_level                 is null then N'' else N', ' + @NL + @indent2 + N'@delete_level='                    + cast(j.delete_level as nvarchar) end +
               case when j.description                  is null then N'' else N', ' + @NL + @indent2 + N'@description=N'''                  + replace(j.description, @APOS, @APOS2) + @APOS end +
               case when j.category_name                is null then N'' else N', ' + @NL + @indent2 + N'@category_name=N'''                + replace(j.category_name, @APOS, @APOS2) + @APOS end +
               case when j.owner_login_name             is null then N'' else N', ' + @NL + @indent2 + N'@owner_login_name=N'''             + replace(j.owner_login_name, @APOS, @APOS2) + @APOS end +
               case when j.notify_email_operator_name   is null then N'' else N', ' + @NL + @indent2 + N'@notify_email_operator_name=N'''   + replace(j.notify_email_operator_name, @APOS, @APOS2) + @APOS end +
               case when j.notify_netsend_operator_name is null then N'' else N', ' + @NL + @indent2 + N'@notify_netsend_operator_name=N''' + replace(j.notify_netsend_operator_name, @APOS, @APOS2) + @APOS end +
               case when j.notify_page_operator_name    is null then N'' else N', ' + @NL + @indent2 + N'@notify_page_operator_name=N'''    + replace(j.notify_page_operator_name, @APOS, @APOS2) + @APOS end +
               N', @job_id = @jobId OUTPUT' + @NL +
               N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as script
        from jobs as j
        union all
        select j.job_id
             , j.job_name
             , N'sp_update_job' as script_part
             , 5 as script_ord
             , N'EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = ' + cast(j.start_step_id as nvarchar) + @NL +
               N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback'
        from jobs as j
        union all
        select j.job_id
             , j.job_name
             , N'sp_add_jobserver' as script_part
             , 7 as script_ord
             , N'EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N''(local)''' + @NL +
               N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback'
        from jobs as j
        union all
        select j.job_id
             , j.job_name
             , N'footer' as script_part
             , 8 as script_ord
             , N'COMMIT TRANSACTION' + @NL +
               N'GOTO EndSave' + @NL +
               N'QuitWithRollback:' + @NL +
               @indent + N'IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION' + @NL +
               N'EndSave:' + @NL + @NL +
               N'GO' + @NL
        from jobs as j

        -- SQL that appears once per step
        ;with steps as (
            select sj.name as job_name
                 , sjs.*
            from msdb.dbo.sysjobsteps sjs
            join msdb.dbo.sysjobs sj
              on sjs.job_id = sj.job_id
           where sj.name = isnull(@object_name, sj.name)
        )
        insert into #sql_parts (obj_guid, obj_name, script_part, script_ord, script_ord2, script)
        select s.job_id
             , s.job_name
             , 'sp_add_jobstep' as script_part
             , 4 as script_ord
             , row_number() over(order by s.step_id) as script_ord2
             , '/****** Object:  Step [' + replace(s.step_name, @APOS, @APOS2) + ']    Script Date: ' + @strnow + ' ******/' +
               @NL + 'EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N''' + replace(s.step_name, @APOS, @APOS2) + @APOS +
               case when s.step_id              is null then '' else N', ' + @NL + @indent2 + '@step_id='              + cast(s.step_id as nvarchar) end +
               case when s.cmdexec_success_code is null then '' else N', ' + @NL + @indent2 + '@cmdexec_success_code=' + cast(s.cmdexec_success_code as nvarchar) end +
               case when s.on_success_action    is null then '' else N', ' + @NL + @indent2 + '@on_success_action='    + cast(s.on_success_action as nvarchar) end +
               case when s.on_success_step_id   is null then '' else N', ' + @NL + @indent2 + '@on_success_step_id='   + cast(s.on_success_step_id as nvarchar) end +
               case when s.on_fail_action       is null then '' else N', ' + @NL + @indent2 + '@on_fail_action='       + cast(s.on_fail_action as nvarchar) end +
               case when s.on_fail_step_id      is null then '' else N', ' + @NL + @indent2 + '@on_fail_step_id='      + cast(s.on_fail_step_id as nvarchar) end +
               case when s.retry_attempts       is null then '' else N', ' + @NL + @indent2 + '@retry_attempts='       + cast(s.retry_attempts as nvarchar) end +
               case when s.retry_interval       is null then '' else N', ' + @NL + @indent2 + '@retry_interval='       + cast(s.retry_interval as nvarchar) end +
               case when s.os_run_priority      is null then '' else N', ' + @NL + @indent2 + '@os_run_priority='      + cast(s.os_run_priority as nvarchar) end +
               case when s.subsystem            is null then '' else N', '                  + '@subsystem=N'''         + replace(s.subsystem, @APOS, @APOS2) + @APOS end +
               case when s.command              is null then '' else N', ' + @NL + @indent2 + '@command=N'''           + replace(s.command, @APOS, @APOS2) + @APOS end +
               case when s.server               is null then '' else N', ' + @NL + @indent2 + '@server=N'''            + replace(s.server, @APOS, @APOS2) + @APOS end +
               case when s.database_name        is null then '' else N', ' + @NL + @indent2 + '@database_name=N'''     + replace(s.database_name, @APOS, @APOS2) + @APOS end +
               case when s.output_file_name     is null then '' else N', ' + @NL + @indent2 + '@output_file_name=N'''  + replace(s.output_file_name, @APOS, @APOS2) + @APOS end +
               case when s.flags                is null then '' else N', ' + @NL + @indent2 + '@flags='                + cast(s.flags as nvarchar) end +
               @NL + 'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as script
        from steps as s

        -- SQL that appears once per job schedule
        ;with sch as (
            select j.job_id
                 , j.name as job_name
                 , ssch.name as schedule_name
                 , ssch.*
            from msdb.dbo.sysjobs j
            join msdb.dbo.sysjobschedules jsch
              on j.job_id = jsch.job_id
            join msdb.dbo.sysschedules ssch
              on jsch.schedule_id = ssch.schedule_id
           where j.name = isnull(@object_name, j.name)
        )
        insert into #sql_parts (obj_guid, obj_name, script_part, script_ord, script_ord2, script)
        select t.job_id
             , t.job_name
             , N'sp_add_jobschedule' as script_part
             , 6 as script_ord
             , row_number() over(order by t.schedule_id) as script_ord2
             , N'EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N''' + replace(t.schedule_name, @APOS, @APOS + @APOS) + @APOS +
               case when t.enabled                is null then '' else N', ' + @NL + @indent2 + '@enabled='                + cast(t.enabled as nvarchar) end +
               case when t.freq_type              is null then '' else N', ' + @NL + @indent2 + '@freq_type='              + cast(t.freq_type as nvarchar) end +
               case when t.freq_interval          is null then '' else N', ' + @NL + @indent2 + '@freq_interval='          + cast(t.freq_interval as nvarchar) end +
               case when t.freq_subday_type       is null then '' else N', ' + @NL + @indent2 + '@freq_subday_type='       + cast(t.freq_subday_type as nvarchar) end +
               case when t.freq_subday_interval   is null then '' else N', ' + @NL + @indent2 + '@freq_subday_interval='   + cast(t.freq_subday_interval as nvarchar) end +
               case when t.freq_relative_interval is null then '' else N', ' + @NL + @indent2 + '@freq_relative_interval=' + cast(t.freq_relative_interval as nvarchar) end +
               case when t.freq_recurrence_factor is null then '' else N', ' + @NL + @indent2 + '@freq_recurrence_factor=' + cast(t.freq_recurrence_factor as nvarchar) end +
               case when t.active_start_date      is null then '' else N', ' + @NL + @indent2 + '@active_start_date='      + cast(t.active_start_date as nvarchar) end +
               case when t.active_end_date        is null then '' else N', ' + @NL + @indent2 + '@active_end_date='        + cast(t.active_end_date as nvarchar) end +
               case when t.active_start_time      is null then '' else N', ' + @NL + @indent2 + '@active_start_time='      + cast(t.active_start_time as nvarchar) end +
               case when t.active_end_time        is null then '' else N', ' + @NL + @indent2 + '@active_end_time='        + cast(t.active_end_time as nvarchar) end +
               case when t.schedule_uid           is null then '' else N', ' + @NL + @indent2 + '@schedule_uid=N'''        + lower(cast(t.schedule_uid as nvarchar(40))) + @APOS end +
               @NL + N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as sql_text
        from sch as t
    end

    -- populate sql_parts for operators
    else if @object_type = 'operators' begin
        ;with operators as (
            select xso.*
                 , xsc.name as category_name
              from msdb.dbo.sysoperators xso
              left join msdb.dbo.syscategories xsc
                on xso.category_id = xsc.category_id
             where xso.name = isnull(@object_name, xso.name)
        )
        insert into #sql_parts (obj_id, obj_name, script_part, script)
        select o.id
             , o.name
             , N'sp_add_operator' as script_part
             , N'/****** Object:  Operator [' + replace(o.name, @APOS, @APOS2) + N']' + case when @include_scriptdate = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
               N'EXEC msdb.dbo.sp_add_operator @name=N''' + replace(o.name, @APOS, @APOS2) + @APOS +
               case when o.enabled                   is null then '' else N',' + @NL + @indent2 + '@enabled='                   + cast(o.enabled as nvarchar) end +
               case when o.weekday_pager_start_time  is null then '' else N',' + @NL + @indent2 + '@weekday_pager_start_time='  + cast(o.weekday_pager_start_time as nvarchar) end +
               case when o.weekday_pager_end_time    is null then '' else N',' + @NL + @indent2 + '@weekday_pager_end_time='    + cast(o.weekday_pager_end_time as nvarchar) end +
               case when o.saturday_pager_start_time is null then '' else N',' + @NL + @indent2 + '@saturday_pager_start_time=' + cast(o.saturday_pager_start_time as nvarchar) end +
               case when o.saturday_pager_end_time   is null then '' else N',' + @NL + @indent2 + '@saturday_pager_end_time='   + cast(o.saturday_pager_end_time as nvarchar) end +
               case when o.sunday_pager_start_time   is null then '' else N',' + @NL + @indent2 + '@sunday_pager_start_time='   + cast(o.sunday_pager_start_time as nvarchar) end +
               case when o.sunday_pager_end_time     is null then '' else N',' + @NL + @indent2 + '@sunday_pager_end_time='     + cast(o.sunday_pager_end_time as nvarchar) end +
               case when o.pager_days                is null then '' else N',' + @NL + @indent2 + '@pager_days='                + cast(o.pager_days as nvarchar) end +
               case when o.email_address             is null then '' else N',' + @NL + @indent2 + '@email_address=N'''          + o.email_address + @APOS end +
               case when o.netsend_address           is null then '' else N',' + @NL + @indent2 + '@netsend_address=N'''        + o.netsend_address + @APOS end +
               case when o.pager_address             is null then '' else N',' + @NL + @indent2 + '@pager_address=N'''          + o.pager_address + @APOS end +
               case when o.category_name             is null then '' else N',' + @NL + @indent2 + '@category_name=N'''          + o.category_name + @APOS end +
               @NL + N'GO' + @NL as script
        from operators as o
    end

    -- assemble results
    insert into #result (script_part, script_ord, script)
    select 'use db'
         , n.num + 1
         , case n.num
           when 0 then 'USE [msdb]'
           when 1 then 'GO'
           when 2 then ''
           end
    from @numbers n
    where n.num < 3

    -- Use the XML split trick on newlines
    insert into #result (obj_id, obj_name, script_part, script_ord, script)
    select s.obj_id
         , s.obj_name
         , s.script_part
         , (isnull(s.script_ord, 0) * 10000000000) +
           (isnull(s.script_ord2, 0) * 100000) +
           row_number() over(partition by s.obj_name, s.script_part
                             order by t.x) as script_ord
         , isnull(t.x.value('text()[1]', 'nvarchar(max)'), '') as script
    from (
        select x.obj_id
             , x.obj_name
             , x.script_part
             , x.script_ord
             , x.script_ord2
             ,  cast('<rows><row>' +
                     replace(replace(replace(x.script, '&', '&amp;'), '<', '&lt;'), @NL, '</row><row>') +
                     '</row></rows>' as xml) as x
        from #sql_parts x
    ) s
    cross apply s.x.nodes('/rows/row') as t(x)
    order by s.obj_name
           , s.script_ord
           , s.script_ord2

    -- clean up
    if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
end

else begin
    -- uh, oh. sp_scripter was called with an object_type we don't know how to handle
    declare @err nvarchar(max) = 'Scripting of specified object type not implemented: ' + isnull(@object_type, '<NULL>')
    raiserror(@err, 16, 1)
    return
end

-- #endregion alerts, jobs, operators
--------------------------------------------------------------------------------
-- #region results

-- select the resulting dataset
select t.row_id
     , isnull(t.obj_type, @object_type) as obj_type
     , t.obj_id
     , t.obj_schema
     , t.obj_name
     , t.script_part
     , t.script_ord
     , t.script
from #result t
order by 1

-- #endregion results

end
go

-- test
exec dbo.sp_scripter 'alerts'
exec dbo.sp_scripter 'jobs'
exec dbo.sp_scripter 'operators'
-- exec dbo.sp_scripter 'nada'
