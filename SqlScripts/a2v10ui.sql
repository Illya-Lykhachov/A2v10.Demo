/* 20171223-7045 */
/*
------------------------------------------------
Copyright � 2008-2017 Alex Kukhtin

Last updated : 23 dec 2017 15:00
module version : 7045
*/
------------------------------------------------
set noexec off;
go
------------------------------------------------
if DB_NAME() = N'master'
begin
	declare @err nvarchar(255);
	set @err = N'Error! Can not use the master database!';
	print @err;
	raiserror (@err, 16, -1) with nowait;
	set noexec on;
end
go
------------------------------------------------
set nocount on;
if not exists(select * from a2sys.Versions where Module = N'std:ui')
	insert into a2sys.Versions (Module, [Version]) values (N'std:ui', 7045);
else
	update a2sys.Versions set [Version] = 7045 where Module = N'std:ui';
go
------------------------------------------------
if not exists(select * from INFORMATION_SCHEMA.SCHEMATA where SCHEMA_NAME=N'a2ui')
begin
	exec sp_executesql N'create schema a2ui';
end
go
if not exists(select * from INFORMATION_SCHEMA.SEQUENCES where SEQUENCE_SCHEMA=N'a2ui' and SEQUENCE_NAME=N'SQ_Menu')
	create sequence a2ui.SQ_Menu as bigint start with 100 increment by 1;
go
------------------------------------------------
if not exists(select * from INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA=N'a2ui' and TABLE_NAME=N'Menu')
begin
	create table a2ui.Menu
	(
		Id	bigint not null constraint PK_Menu primary key
			constraint DF_Menu_PK default(next value for a2ui.SQ_Menu),
		Parent bigint null
			constraint FK_Menu_Parent_Menu foreign key references a2ui.Menu(Id),
		Name nvarchar(255) null,
		Url nvarchar(255) null,
		Icon nvarchar(255) null,
		Model nvarchar(255) null,
		[Order] int not null constraint DF_Menu_Order default(0),
		[Description] nvarchar(255) null
	);
end
go
------------------------------------------------
if not exists(select * from INFORMATION_SCHEMA.TABLES where TABLE_SCHEMA=N'a2security' and TABLE_NAME=N'Menu.Acl')
begin
	-- ACL for menu
	create table a2security.[Menu.Acl]
	(
		Menu bigint not null 
			constraint FK_MenuAcl_Menu foreign key references a2ui.Menu(Id),
		UserId bigint not null 
			constraint FK_MenuAcl_UserId_Users foreign key references a2security.Users(Id),
		CanView bit null,
		[Permissions] as cast(CanView as int)
		constraint PK_MenuAcl primary key(Menu, UserId)
	);
end
go
------------------------------------------------
if exists (select * from INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA=N'a2ui' and ROUTINE_NAME=N'Menu.User.Load')
	drop procedure a2ui.[Menu.User.Load]
go
------------------------------------------------
create procedure a2ui.[Menu.User.Load]
@UserId bigint
as
begin
	set nocount on;
	-- TODO: 
	-- 1. get default root for user
	-- 4.
	declare @RootId bigint = 1;
	with RT as (
		select Id=m0.Id, ParentId = m0.Parent, [Level]=0
			from a2ui.Menu m0
			where m0.Id = @RootId
		union all
		select m1.Id, m1.Parent, RT.[Level]+1
			from RT inner join a2ui.Menu m1 on m1.Parent = RT.Id
	)
	select [Menu!TMenu!Tree] = null, [Id!!Id]=RT.Id, [!TMenu.Menu!ParentId]=RT.ParentId,
		[Menu!TMenu!Array] = null,
		m.Name, m.Url, m.Icon, m.[Description]
	from RT 
		inner join a2security.[Menu.Acl] a on a.Menu = RT.Id
		inner join a2ui.Menu m on RT.Id=m.Id
	where a.UserId = @UserId and a.CanView = 1
	order by RT.[Level], m.[Order], RT.[Id];

	-- system parameters
	select [SysParams!TParam!Object]= null, [AppTitle], [AppSubTitle]
	from (select Name, Value=StringValue from a2sys.SysParams) as s
		pivot (min(Value) for Name in ([AppTitle], [AppSubTitle])) as p;
end
go
------------------------------------------------
if exists (select * from INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA=N'a2ui' and ROUTINE_NAME=N'AppTitle.Load')
	drop procedure a2ui.[AppTitle.Load]
go
------------------------------------------------
create procedure a2ui.[AppTitle.Load]
as
begin
	set nocount on;
	select [AppTitle], [AppSubTitle]
	from (select Name, Value=StringValue from a2sys.SysParams) as s
		pivot (min(Value) for Name in ([AppTitle], [AppSubTitle])) as p;
end
go
-----------------------------------------------
if exists (select * from sys.objects where object_id = object_id(N'a2security.fn_GetMenuFor') and type in (N'FN', N'IF', N'TF', N'FS', N'FT'))
	drop function a2security.fn_GetMenuFor;
go
------------------------------------------------
create function a2security.fn_GetMenuFor(@MenuId bigint)
returns @rettable table (Id bigint, Parent bit)
as
begin
	declare @tx table (Id bigint, Parent bit);

	-- all children
	with �(Id, ParentId)
	as
	(
		select @MenuId, cast(null as bigint) 
		union all
		select m.Id, m.Parent
			from a2ui.Menu m inner join � on m.Parent=�.Id
	)
	insert into @tx(Id, Parent)
		select Id, 0 from �
		group by Id;

	-- all parent 
	with P(Id, ParentId)
	as
	(
		select cast(null as bigint), @MenuId 
		union all
		select m.Id, m.Parent
			from a2ui.Menu m inner join P on m.Id=P.ParentId
	)
	insert into @tx(Id, Parent)
		select Id, 1 from P
		group by Id;

	insert into @rettable
		select Id, Parent from @tx
			where Id is not null
		group by Id, Parent;
	return;
end
go
------------------------------------------------
if exists (select * from INFORMATION_SCHEMA.ROUTINES where ROUTINE_SCHEMA=N'a2security' and ROUTINE_NAME=N'Permission.UpdateAcl.Menu')
	drop procedure [a2security].[Permission.UpdateAcl.Menu]
go
------------------------------------------------
create procedure [a2security].[Permission.UpdateAcl.Menu]
as
begin
	set nocount on;
	declare @MenuTable table (Id bigint, UserId bigint, GroupId bigint, CanView smallint);

	insert into @MenuTable (Id, UserId, GroupId, CanView)
		select f.Id, a.UserId, a.GroupId, a.CanView
		from a2security.Acl a 
			cross apply a2security.fn_GetMenuFor(a.ObjectId) f
			/*exclude denied parents */
		where a.[Object] = N'std:menu' and Not (Parent = 1 and CanView = -1)
		group by f.Id, UserId, GroupId, CanView;

	declare @UserTable table (ObjectId bigint, UserId bigint, CanView bit);

	with T(ObjectId, UserId, CanView)
	as
	(
		select a.Id, UserId=isnull(ur.UserId, a.UserId), a.CanView
		from @MenuTable a
		left join a2security.UserGroups ur on a.GroupId = ur.GroupId
		where isnull(ur.UserId, a.UserId) is not null
	)
	insert into @UserTable(ObjectId, UserId, CanView)
	select ObjectId, UserId,
		_CanView = isnull(case 
				when min(T.CanView) = -1 then 0
				when max(T.CanView) = 1 then 1
				end, 0)
	from T
	group by ObjectId, UserId;

	merge a2security.[Menu.Acl] as target
	using
	(
		select ObjectId, UserId, CanView
		from @UserTable T
		where CanView = 1
	) as source(ObjectId, UserId, CanView)
		on target.Menu = source.[ObjectId] and target.UserId=source.UserId
	when matched then
		update set 
			target.CanView = source.CanView
	when not matched by target then
		insert (Menu, UserId, CanView)
			values (source.[ObjectId], source.UserId, source.CanView)
	when not matched by source then
		delete;
end
go
------------------------------------------------
begin
	set nocount on;
	grant execute on schema ::a2ui to public;
end
go
------------------------------------------------
set noexec off;
go
