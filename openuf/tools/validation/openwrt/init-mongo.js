db.getSiblingDB("unifi").createUser({user: "unifi", pwd: "benchpass", roles: [{role: "dbOwner", db: "unifi"}, {role: "dbOwner", db: "unifi_stat"}, {role: "dbOwner", db: "unifi_audit"}]});
