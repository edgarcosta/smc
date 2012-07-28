#!/usr/bin/env python
"""

Copyright (c) William Stein, 2012.  Not open source or free. Will be
assigned to University of Washington.
"""

import os, time

import daemon

import misc

def mtime(file):
    try:
        return os.path.getmtime(file)
    except OSError:
        return 0

from sqlalchemy import (Column, DateTime, Integer, String, func)

from sqlalchemy.ext.declarative import declarative_base
Base = declarative_base()

class LogMessage(Base):
    __tablename__ = "log"
    id = Column(Integer, primary_key=True, autoincrement=True)
    logfile = Column(String)
    time = Column(DateTime, default=func.now())
    message = Column(String)

    def __init__(self, message, logfile):
        self.message = message
        self.logfile = logfile

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
session_maker = None

def get_session(database):
    global session_maker
    if session_maker is None:
        engine = create_engine(database)
        Base.metadata.create_all(engine)
        session_maker = sessionmaker(bind=engine)
    return session_maker()

def send_log_to_database(database, logfile, filename):
    print "Get new connection..."
    session = get_session(database)
    c = open(logfile).read()
    if len(c) == 0:
        print "logfile is empty"
        continue
    for r in c.splitlines():
        session.add(LogMessage(r, filename))
    session.commit()
    session.close()
    print "Successful commit, now deleting file..."
    if mtime(logfile) != lastmod:
        # file appended to during db send, so delete the part of file we sent (but not the rest)
        open(logfile,'w').write(open(logfile).read()[len(c):])
    else:
        # just clear file
        open(logfile,'w').close()
    lastmod = mtime(logfile)

def watched_process_still_running(watched_pidfile):
    if not os.path.exists(watched_pidfile):
        return False
    try:
        # pidfiles sometimes have more info in them; first line is always master pid
        if not misc.is_running(int(open(watched_pidfile).readlines()[0])):
            return False
    except IOError:  # in case file vanished after above check.
        return os.path.exists(watched_pidfile)
    return True

def main(logfile, pidfile, watched_pidfile, timeout, database):
    filename = os.path.split(logfile)[-1]
    try:
        open(pidfile,'w').write(str(os.getpid()))
        lastmod = None
        while True:
            modtime = mtime(logfile)
            if lastmod != modtime:
                lastmod = modtime
                try:
                    send_log_to_database(database, logfile, filename)
                except Exception, msg:
                    print msg
            print "Sleeping %s seconds"%timeout
            time.sleep(timeout)
            if not watched_process_still_running(watched_pidfile):
                return
    finally:
        os.unlink(pidfile)

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Log watcher check on the logfile every to t seconds to see if it changes.  If so, it ships off the contents to the database, and on successful DB commit empties the file.  This is subject to race conditions that could result in a small amount of lost or corrupted data, but the simplicity of implementing this for all clients makes it worth it.")

    parser.add_argument("-g", dest='debug', default=False, action="store_const", const=True,
                        help="debug mode (default: False)")
    parser.add_argument("-l", dest='logfile', type=str, required=True,
                        help="when this file changes it is sent to the database server")
    parser.add_argument("-d", dest="database", type=str, required=True,
                        help="SQLalchemy description of database server, e.g., postgresql://user@hostname:port/dbname")
    parser.add_argument("-p", dest="pidfile", type=str, required=True,
                        help="PID file of this daemon process")
    parser.add_argument("-t", dest="timeout", type=int, default=60,  
                        help="check every t seconds to see if logfile has changed")
    parser.add_argument("-w", dest="watched_pidfile", type=str, required=True,
                        help="pid of the process being watched")
    
    args = parser.parse_args()
        
    logfile = os.path.abspath(args.logfile)
    pidfile = os.path.abspath(args.pidfile)
    watched_pidfile = os.path.abspath(args.watched_pidfile)

    f = lambda: main(logfile=logfile, pidfile=pidfile, watched_pidfile=watched_pidfile,
                     timeout=args.timeout, database=args.database)
    if args.debug:
        f()
    else:
        with daemon.DaemonContext():
            f()
    
    
    
