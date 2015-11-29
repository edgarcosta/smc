###
Manage storage

###

async       = require('async')
winston     = require('winston')

misc_node   = require('smc-util-node/misc_node')

misc        = require('smc-util/misc')
{defaults, required} = misc

# Set the log level
winston.remove(winston.transports.Console)
winston.add(winston.transports.Console, {level: 'debug', timestamp:true, colorize:true})

exclude = () ->
    return ("--exclude=#{x}" for x in misc.split('.sage/cache .sage/temp .trash .Trash .sagemathcloud .smc .node-gyp .cache .forever .snapshots *.sage-backup'))

# Low level function that save all changed files from a compute VM to a local path.
# This must be run as root.
copy_project_from_compute_to_storage = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of computer, e.g., compute2-us
        path       : required    # target path, e.g., /projects0
        max_size_G : 50
        delete     : true
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_compute_to_storage(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}', path='#{opts.path}'")
    args = ['rsync', '-axH', "--max-size=#{opts.max_size_G}G", "--ignore-errors"]
    if opts.delete
        args = args.concat(["--delete", "--delete-excluded"])
    else
        args.push('--update')
    args = args.concat(exclude())
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "#{opts.host}:/projects/#{opts.project_id}/"
    target = "#{opts.path}/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'sudo'
        args        : args
        timeout     : 10000
        verbose     : true
        err_on_exit : true
        cb          : (err, output) ->
            if err and output?.exit_code == 24 or output?.exit_code == 23
                # exit code 24 = partial transfer due to vanishing files
                # exit code 23 = didn't finish due to permissions; this happens due to fuse mounts
                err = undefined
            dbg("...finished rsync -- time=#{misc.walltime(start)}s")#; #{misc.to_json(output)}")
            opts.cb(err)

# copy_project_from_storage_to_compute NEVER TESTED!
copy_project_from_storage_to_compute = (opts) ->
    opts = defaults opts,
        project_id : required    # uuid
        host       : required    # hostname of computer, e.g., compute2-us
        path       : required    # local source path, e.g., /projects0
        cb         : required
    dbg = (m) -> winston.debug("copy_project_from_storage_to_compute(project_id='#{opts.project_id}'): #{m}")
    dbg("host='#{opts.host}', path='#{opts.path}'")
    args = ['rsync', '-axH']
    args = args.concat(['-e', 'ssh -T -c arcfour -o Compression=no -x  -o StrictHostKeyChecking=no'])
    source = "#{opts.path}/#{opts.project_id}/"
    target = "#{opts.host}:/projects/#{opts.project_id}/"
    args = args.concat([source, target])
    dbg("starting rsync...")
    start = misc.walltime()
    misc_node.execute_code
        command     : 'sudo'
        args        : args
        timeout     : 10000
        verbose     : true
        err_on_exit : true
        cb          : (out...) ->
            dbg("finished rsync -- time=#{misc.walltime(start)}s")
            opts.cb(out...)

get_host_and_storage = (project_id, database, cb) ->
    dbg = (m) -> winston.debug("get_host_and_storage(project_id='#{project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            dbg("determine project location info")
            database.table('projects').get(project_id).pluck(['storage', 'host']).run (err, x) ->
                if err
                    cb(err)
                else if not x?
                    cb("no such project")
                else
                    host    = x.host?.host
                    storage = x.storage?.host
                    if not host?
                        cb("project not currently open on a compute host")
                    else
                        cb()
        (cb) ->
            if storage?
                cb()
                return
            dbg("allocate storage host")
            database.table('storage_servers').pluck('host').run (err, x) ->
                if err
                    cb(err)
                else if not x? or x.length == 0
                    cb("no storage servers in storage_server table")
                else
                    # TODO: could choose based on free disk space
                    storage = misc.random_choice((a.host for a in x))
                    database.set_project_storage
                        project_id : project_id
                        host       : storage
                        cb         : cb
    ], (err) ->
        cb(err, {host:host, storage:storage})
    )


# Save project from compute VM to its assigned storage server.  Error if project
# not opened on a compute VM.
exports.save_project = save_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required    # uuid
        max_size_G : 50
        cb         : required
    dbg = (m) -> winston.debug("save_project(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            get_host_and_storage opts.project_id, opts.database, (err, x) ->
                if err
                    cb(err)
                else
                    {host, storage} = x
                    cb()
        (cb) ->
            dbg("do the save")
            copy_project_from_compute_to_storage
                project_id : opts.project_id
                host       : host
                path       : "/" + storage   # TODO: right now all on same computer...
                cb         : cb
        (cb) ->
            dbg("save succeeded -- record in database")
            opts.database.update_project_storage_save
                project_id : opts.project_id
                cb         : cb
    ], (err) -> opts.cb(err))

# Save all projects that have been modified in the last age_m minutes.
# If there are errors, then will get cb({project_id:'error...', ...})
exports.save_all_projects = (opts) ->
    opts = defaults opts,
        database : required
        age_m    : required  # save all projects with last_edited at most this long ago in minutes
        threads  : 10        # number of saves to do at once.
        cb       : required
    dbg = (m) -> winston.debug("save_all_projects(last_edited_m:#{opts.age_m}): #{m}")
    dbg()
    errors = {}
    opts.database.recent_projects
        age_m : opts.age_m
        cb    : (err, projects) ->
            if err
                opts.cb(err)
                return
            dbg("got #{projects.length} projects")
            n = 0
            f = (project_id, cb) ->
                n += 1
                m = n
                dbg("#{m}/#{projects.length}: START")
                save_project
                    project_id : project_id
                    database   : opts.database
                    cb         : (err) ->
                        dbg("#{m}/#{projects.length}: DONE  -- #{err}")
                        if err
                            errors[project_id] = err
                        cb()
            async.mapLimit projects, opts.threads, f, () ->
                opts.cb(if misc.len(errors) > 0 then errors)

# NEVER TESTED!
# Open project on a given compute server (so copy from storage to compute server).
# Error if project is already open on a server.
exports.open_project = open_project = (opts) ->
    opts = defaults opts,
        database   : required
        project_id : required
        cb         : required
    dbg = (m) -> winston.debug("open_project(project_id='#{opts.project_id}'): #{m}")
    host = undefined
    storage = undefined
    async.series([
        (cb) ->
            dbg('make sure project is not already opened somewhere')
            opts.database.get_project_host
                project_id : opts.project_id
                cb         : (err, x) ->
                    if err
                        cb(err)
                    else
                        if x?.host?
                            cb("project already opened")
                        else
                            cb()
        (cb) ->
            get_host_and_storage opts.project_id, opts.database, (err, x) ->
                if err
                    cb(err)
                else
                    {host, storage} = x
                    cb()
        (cb) ->
            dbg("do the open")
            copy_project_from_storage_to_compute
                project_id : opts.project_id
                host       : host
                path       : "/" + storage   # TODO: right now all on same computer...
                cb         : cb
        (cb) ->
            dbg("open succeeded -- record in database")
            opts.database.set_project_host
                project_id : opts.project_id
                host       : host
                cb         : cb
    ], opts.cb)


###
Everything below is one-off code -- has no value, except as examples.
###

# Slow one-off function that goes through database, reads each storage field for project,
# and writes it in a different format: {host:host, assigned:assigned}.
exports.update_storage_field = (opts) ->
    opts = defaults opts,
        db      : required
        lower   : required
        upper   : required
        limit   : undefined
        threads : 1
        cb      : required
    dbg = (m) -> winston.debug("update_storage_field: #{m}")
    dbg("query database for projects with id between #{opts.lower} and #{opts.upper}")
    query = opts.db.table('projects').between(opts.lower, opts.upper)
    query = query.pluck('project_id', 'storage')
    if opts.limit?
        query = query.limit(opts.limit)
    query.run (err, x) ->
        if err
            opts.cb(err)
        else
            dbg("got #{x.length} results")
            n = 0
            f = (project, cb) ->
                n += 1
                dbg("#{n}/#{x.length}: #{misc.to_json(project)}")
                if project.storage? and not project.storage?.host?
                    y = undefined
                    for host, assigned of project.storage
                        y = {host:host, assigned:assigned}
                    if y?
                        dbg(misc.to_json(y))
                        opts.db.table('projects').get(project.project_id).update(storage:opts.db.r.literal(y)).run(cb)
                    else
                        cb()
                else
                    cb()
            async.mapLimit(x, opts.threads, f, (err)=>opts.cb(err))




# A one-off function that queries for some projects
# in the database that don't have storage set, and assigns them a given host,
# then copies their data to that host.

exports.migrate_projects = (opts) ->
    opts = defaults opts,
        db      : required
        lower   : required
        upper   : required
        host    : 'projects0'
        all     : false
        limit   : undefined
        threads : 1
        cb      : required
    dbg = (m) -> winston.debug("migrate_projects: #{m}")
    projects = undefined
    async.series([
        (cb) ->
            dbg("query database for projects with id between #{opts.lower} and #{opts.upper}")
            query = opts.db.table('projects').between(opts.lower, opts.upper)
            if not opts.all
                query = query.filter({storage:true}, {default:true})
            query = query.pluck('project_id')
            if opts.limit?
                query = query.limit(opts.limit)
            query.run (err, x) ->
                projects = x; cb(err)
        (cb) ->
            n = 0
            migrate_project = (project, cb) ->
                {project_id} = project
                m = n
                dbg("#{m}/#{projects.length-1}: do rsync for #{project_id}")
                src = "/projects/#{project_id}/"
                n += 1
                fs.exists src, (exists) ->
                    if not exists
                        dbg("#{m}/#{projects.length-1}: #{src} -- source not available -- setting storage to empty map")
                        opts.db.table('projects').get(project_id).update(storage:{}).run(cb)
                    else
                        cmd = "sudo rsync -axH --exclude .sage #{src}    /#{opts.host}/#{project_id}/"
                        dbg("#{m}/#{projects.length-1}: " + cmd)
                        misc_node.execute_code
                            command     : cmd
                            timeout     : 10000
                            verbose     : true
                            err_on_exit : true
                            cb          : (err) ->
                                if err
                                    cb(err)
                                else
                                    dbg("it worked, set storage entry in database")
                                    opts.db.table('projects').get(project_id).update(storage:{"#{opts.host}":new Date()}).run(cb)

            async.mapLimit(projects, opts.threads, migrate_project, cb)

    ], (err) ->
        opts.cb?(err)
    )




