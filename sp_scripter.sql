-- use master
-- go
if objectproperty(object_id('dbo.sp_scripter'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_scripter as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_scripter
-- author   : mattmc3
-- version  : v0.0.1
-- homepage : https://github.com/mattmc3/sp_scripter
-- license  : MIT - https://github.com/mattmc3/sp_scripter/blob/master/LICENSE
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
    ,obj_schema nvarchar(128)
    ,obj_name nvarchar(128)
    ,script_part nvarchar(256)
    ,script_seq int not null
    ,script nvarchar(max) not null
)

-- #endregion setup
--------------------------------------------------------------------------------
-- #region alerts, jobs, operators

if @object_type in ('alerts', 'jobs', 'operators') begin

    -- make a table to help assemble the results
    if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
    create table #sql_parts (
        obj_id int
        ,obj_name nvarchar(512)
        ,script_part nvarchar(128)
        ,script nvarchar(max)
    )

    -- populate sql_parts for alerts
    if @object_type = 'alerts' begin
        -- SQL that appears once per alert schedule
        ;with alerts as (
            select xsa.*
                 , xsc.name as category_name
            from msdb.dbo.sysalerts xsa
            join msdb.dbo.syscategories xsc
              on xsa.category_id = xsc.category_id
           where xsa.name = isnull(@object_name, xsa.name)
        )
        insert into #sql_parts
        select t.id
             , t.name
             , N'sp_add_alert' as script_part
             , N'/****** Object:  Alert [' + replace(t.name, @APOS, @APOS + @APOS) + N']' + case when @include_scriptdate = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
               N'EXEC msdb.dbo.sp_add_alert @name=N''' + replace(t.name, @APOS, @APOS + @APOS) + @APOS +
               case when t.message_id                is null then '' else N',' + @NL + @indent2 + '@message_id='                   + cast(t.message_id as nvarchar) end +
               case when t.severity                  is null then '' else N',' + @NL + @indent2 + '@severity='                     + cast(t.severity as nvarchar) end +
               case when t.enabled                   is null then '' else N',' + @NL + @indent2 + '@enabled='                      + cast(t.enabled as nvarchar) end +
               case when t.delay_between_responses   is null then '' else N',' + @NL + @indent2 + '@delay_between_responses='      + cast(t.delay_between_responses as nvarchar) end +
               case when t.include_event_description is null then '' else N',' + @NL + @indent2 + '@include_event_description_in=' + cast(t.include_event_description as nvarchar) end +
               case when t.category_name             is null then '' else N',' + @NL + @indent2 + '@category_name=N'''             + cast(t.category_name as nvarchar(40)) + @APOS end +
               case when t.job_id                    is null then '' else N',' + @NL + @indent2 + '@job_id=N'''                    + lower(cast(t.job_id as nvarchar(40))) + @APOS end +
               @NL + N'GO' + @NL as script
        from alerts t
    end

    -- assemble results
    insert into #result (script_part, script_seq, script)
    select 'use statement'
         , n.num
         , case n.num
           when 0 then 'USE [msdb]'
           when 1 then 'GO'
           when 2 then ''
           end
    from @numbers n
    where n.num < 3

    -- Use XML trick to split on newlines
    insert into #result (obj_id, obj_name, script_part, script_seq, script)
    select s.obj_id
         , s.obj_name
         , s.script_part
         , row_number() over(partition by s.obj_name, s.script_part
                             order by t.x) as seq
         , isnull(t.x.value('text()[1]', 'nvarchar(max)'), '') as script
    from (
        select x.obj_id
             , x.obj_name
             , x.script_part
             ,  cast('<rows><row>' +
                     replace(replace(replace(x.script, '&', '&amp;'), '<', '&lt;'), @NL, '</row><row>') +
                     '</row></rows>' as xml) as x
        from #sql_parts x
    ) s
    cross apply s.x.nodes('/rows/row') as t(x)
    order by s.obj_name
           , s.script_part
           , seq

    -- clean up
    if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
end

-- #endregion alerts, jobs, operators
--------------------------------------------------------------------------------
-- #region results

-- return the results
select t.row_id
     , isnull(t.obj_type, @object_type) as obj_type
     , t.obj_id
     , t.obj_schema
     , t.obj_name
     , t.script_part
     , t.script_seq
     , t.script
from #result t
order by 1

end
go

-- test
exec dbo.sp_scripter 'alerts'
