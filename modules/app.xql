xquery version "3.1";

module namespace app="http://exist.jmmc.fr/catalogs/templates";

import module namespace templates="http://exist-db.org/xquery/templates" ;
import module namespace config="http://exist.jmmc.fr/catalogs/config" at "config.xqm";

import module namespace oidb-config="http://apps.jmmc.fr/exist/apps/oidb/config" at "../../oidb/modules/config.xqm";
import module namespace user="http://apps.jmmc.fr/exist/apps/oidb/restxq/user" at "../../oidb/modules/rest/user.xqm";

import module namespace sql-utils="http://apps.jmmc.fr/exist/apps/oidb/sql-utils" at "../../oidb/modules/sql-utils.xql";
import module namespace log="http://apps.jmmc.fr/exist/apps/oidb/log" at "../../oidb/modules/log.xqm";
import module namespace adql="http://apps.jmmc.fr/exist/apps/oidb/adql" at "../../oidb/modules/adql.xqm";
import module namespace oidb-tap="http://apps.jmmc.fr/exist/apps/oidb/tap" at "../../oidb/modules/tap.xqm";

import module namespace jmmc-tap="http://exist.jmmc.fr/jmmc-resources/tap" at "/db/apps/jmmc-resources/content/jmmc-tap.xql";

import module namespace sql="http://exist-db.org/xquery/sql";

import module namespace http = "http://expath.org/ns/http-client";

declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";
declare namespace rest="http://exquery.org/ns/restxq";
(:declare namespace xsns="http://www.w3.org/2001/XMLSchema"; :)

declare variable $app:ACCESS_LABEL := map { true() : "" , false() : <i class="glyphicon glyphicon-lock" aria-hidden="true"/>};

(:
 : - try not to return 500 errors and prefer 400 so the client will consume and not loop over with retries
 : - check authentication for every sensible operations :
 :     - read protected data
 :     - modify content
 : TODO add a version on api ?
 : TODO separate low level code from api ? move code in catalogs anyway...
 : TODO add constant for errors
 : TODO enhance a rest xml response function : (@reason is not forwarded to python caller. -> add error in json response)
 :
 : TODO document that  our approach relies on the fact that every cats have a single primary key used for update statements
 :)

(:~
 : Generates main table of catalogs.
 :
 : @param $node the HTML node with the attribute which triggered this call
 : @param $model a map containing arbitrary data - used to pass information between template calls
 :)
declare function app:catalogs-table($node as node(), $model as map(*)) {
    <div>
        <h2>Catalog list</h2>
        {
            if( request:get-parameter("clear-cache", () ) ) then ( cache:clear(),  <div class="alert alert-warning" role="alert"> Cache cleared. </div> ) else ()
        }
        <div>
            <table id="mixedtable" class="display table table-bordered nowrap">
            <thead><tr><th>Name</th><th>Description</th><th>Access</th></tr></thead>
            <tbody>
            {
                let $cats := app:get-catalogs()
                let $log := util:log("info", $cats)
                for $name in map:keys($cats) order by $name
                    let $desc := $cats($name)
                    return
                        <tr><td><a href="show.html?name={$name}">{$name}</a></td><td>{$desc}</td><td>{$app:ACCESS_LABEL(app:is-public($name))}</td></tr>
            }
            </tbody>
            </table>
        </div>
    </div>
};

(:~
 : Generates main table of catalogs.
 :
 : @param $node the HTML node with the attribute which triggered this call
 : @param $model a map containing arbitrary data - used to pass information between template calls
 :)
declare function app:show-catalog($node as node(), $model as map(*), $name as xs:string, $table as xs:string?) {
    if(exists($table))
    then app:show-catalog-table($node, $model, $name)
    else app:show-catalog-desc($node, $model, $name)
};

(:~
 : Generates table of catalog.
 :
 : @param $node the HTML node with the attribute which triggered this call
 : @param $model a map containing arbitrary data - used to pass information between template calls
 :)
declare function app:show-catalog-table($node as node(), $model as map(*), $name as xs:string) {
    let $primary-key := app:get-catalog-primary-key($name)
    let $metadata := app:get-metadata($name)

    (:
    prefer progressiveLoad which can sort whole content. TODO check on large catalogs...
    pagination:true, //enable pagination
    paginationMode:"remote", //enable remote pagination
    paginationSize:100, //optional parameter to request a certain number of rows per page
     :)
    return
    <div>
        <div id="example-table"></div>
        <script>
            //Build Tabulator
            var table = new Tabulator("#example-table", {{
                index:"{$primary-key}",
                progressiveLoad:"load",
                paginationSize:10000,
                height:"500px",
                layout:"fitColumns",
                placeholder:"No Data Set",
                columns:[
                    {
                        for $meta in $metadata return '{title:"'||$meta("name")||'", field:"'||$meta("name")||'" , editor:"input" },'
                    }
                ],
                initialSort:[             //set the initial sort order of the data
                {{column:"name", dir:"asc"}},
                ],
                ajaxURL:"./modules/tabular-data.xql", //set url for ajax request
                ajaxParams:{{catalog:"{$name}"}}, //set any standard parameters to pass with the request
            }});

            table.on("cellEdited", function(cell){{
                console.log("edited cell : "+ cell);
            }});

            //trigger AJAX load on "Load Data via AJAX" button click
            document.getElementById("ajax-trigger").addEventListener("click", function(){{
                table.setData("./modules/tabular-data.xql?catalog={encode-for-uri($name)}");
            }});
        </script>
    </div>
};

(:~
 : Generates description of catalog.
 :
 : @param $node the HTML node with the attribute which triggered this call
 : @param $model a map containing arbitrary data - used to pass information between template calls
 :)
declare function app:show-catalog-desc($node as node(), $model as map(*), $name as xs:string) {
    let $c := if( request:get-parameter("clear-cache", () ) ) then ( cache:clear(),  <div class="alert alert-warning" role="alert"> Cache cleared. </div> ) else ()
    let $primary-key := app:get-catalog-primary-key($name)
    let $metadata := app:get-metadata($name)
(:    :)
    let $keys := distinct-values( ("name", "description", for $m in $metadata return map:keys($m)))
    let $max-len := 200
    return
    <div>
        <h1>{$name} catalog </h1>
        {$c}
        {if(app:is-public($name)) then () else <h3>Content access is restricted {$app:ACCESS_LABEL(app:is-public($name))}</h3>}
        {if(exists($primary-key)) then <div><h3>Catalog's primary key : <b>{$primary-key}</b></h3><p> Please use {$primary-key} as key for your record's updates.</p></div> else ()}
        <h2>Column descriptions</h2>
        <div>
            <table id="mixedtable" class="display table table-bordered nowrap">
            <thead><tr>{for $key in $keys return <th>{$key}</th>}</tr></thead>
            <tbody>
            {
                for $meta in $metadata
                return
                    <tr>{
                        let $elname := if( $primary-key=$meta("name") ) then "b" else "span"
                        for $key in $keys
                            let $value := $meta($key)
                            let $value := if(string-length($value)>$max-len) then <span title="{$value}">{substring($value,1,$max-len)}...</span> else $value
                            return <td>{element {$elname} {$value}}</td>}</tr>
            }
            </tbody>
            </table>
        </div>
         <p>Please find some links to check/improve your table metadata :<ul>
            <li><a href="http://dc.zah.uni-heidelberg.de/ucds/ui/ui/form">using GAVO's UCD resolver</a></li>
            <li><a href="http://cdsarc.u-strasbg.fr/doc/catstd.htx">Standards for Astronomical Catalogues provided by CDS</a></li>
            <li><a href="https://www.iau.org/publications/proceedings_rules/units/">IAU Recommendations concerning Units</a></li>
            </ul></p>
    </div>

(:    return <pre>TODO</pre>:)
};

declare function app:get-metadata($catalog-name){
    let $primary-key := app:get-catalog-primary-key($catalog-name)
    (: ask for 0 data but metadata ( query result is cached ) :)
    let $res := jmmc-tap:tap-adql-query($oidb-config:TAP_SYNC,"SELECT TOP 0 * FROM "||$catalog-name, (), "application/json")
    let $json := for $m in $res?metadata?*
        return if ( $m?name = $primary-key) then map:merge(($m,map {"primary-key":true()}))
            else $m
    return $json
};

(:~
 :
 :
 :)
declare function app:get-catalog-primary-key($catalog-name){
    if( starts-with($catalog-name, "spica") and not (matches($catalog-name, "spica_cal|spica_followup|spica_test_followup" )) )
    then
        "spicadb_id"
    else if(starts-with($catalog-name, "obsportal"))
    then
        "exp_id"
    else if(matches($catalog-name, "spica_followup|spica_test_followup"))
    then
        "tpl_start"
    else
        "id"
};

(:~
 : Return the name of the column that is used by the API to automatically store mofifications.
 : TODO search such info in the catalog metadata
 : @param $catalog-name the name of catalog to update.
 :
 :
 :)
declare function app:get-catalog-lastmods($catalog-name){
    if( starts-with($catalog-name, "spica") and not (matches($catalog-name, "spica_cal|spica_test_followup|spica_followup" )) )
    then
        "lastmods" (: not sure we put it on first version but ok from 2022_03_30 :)
    else
        ()
};

declare function app:is-public($catalog-name as xs:string)
{
    (: TODO finish implementation:  handle groups and read config from catalog metadata ... :)

    (: mockup :)
    let $public-cats := ("oidb", "obsportal")
    return starts-with($catalog-name, $public-cats)
};


declare function app:has-access($catalog-name as xs:string, $mode as xs:string)
{
    (: TODO finish implementation:  handle groups and read config from catalog metadata ... :)

    (: mockup :)
    let $public-cats := ("oidb")
    let $public := starts-with($catalog-name, $public-cats)
    return
        if( $public ) then
            true()
        else
            (: TODO replace is authenticated by  is-pi-or-delegated-user() :)
            let $isaut := try {app:is-authenticated()} catch * {false()}
            let $isadm := try {app:is-admin($catalog-name)} catch * {false()}
            return
                if ( $isaut or $isadm ) then
                    true()
                else
                    let $reason := "Catalog is not public"
                    return error(
                            xs:QName("app:rest-error"), $reason,
                            app:rest-response(401,$reason)
                            )
};

declare function app:get-catalog-pi-name($catalog-name as xs:string){
    (: TODO retrieve using ucd data pi:)
    if( starts-with($catalog-name, "spica") )
    then
        if ( matches($catalog-name, "spica_cal|spica_followup|spica_test_followup" ) ) then
            "piname"
        else
            ("piname","piname2")
    else
        "datapi"
};

declare
    %rest:PUT("{$delegations}")
    %rest:path("/catalogs/delegations")
    %rest:consumes("application/json")
    %rest:produces("application/json")
    %output:method("json")
function app:update-delegations($delegations) {
    let $json := parse-json(util:base64-decode($delegations))
    let $json := if ($json instance of xs:string) then parse-json($json) else $json (: We can get the json or its string serialization :)
    return $json
};

declare function app:get-pi-delegations($pi as xs:string){
    array {
        for $delegation in user:get-delegations($pi)//delegation
            return
                map:merge((
                    ( $delegation/catalogs,$delegation/collections) ! map { name(.) : data(.) }
                    ,map{ "coi": array{ data($delegation/alias) } }
                ))
    }
};

declare
    %rest:GET
    %rest:path("/catalogs/delegations")
    %rest:produces("application/json")
    %rest:query-param("pi", "{$pi}")
    %output:method("json")
function app:get-delegations($pi as xs:string*) {
    try{
        (: throw error if not authenticated anonymous calls :)
        let $check-auth := app:is-authenticated()
        (: TODO limit to admins? or logged user
            if admin list every delegation else restrict to the logged user associated pi name
        :)
        let $pi := if ($pi) then $pi else data(sm:id()//*:username)
        let $delegations := app:get-pi-delegations($pi)
        return
            map{
                "pi" : $pi
                ,"delegations": $delegations
                ,"login": data(sm:id()//*:username)
            }
    } catch app:rest-error {
        $err:value
    } catch * {
        app:rest-response(400,string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};

declare function app:get-pi-aliases($login) {
    let $datapis := data($user:people-doc//person[.//@email=$login]/alias)
    let $log := util:log("info" ,"aliases found for login=" || $login || " : " ||string-join($datapis, ", "))
    return $datapis
};

(:~
 : Test if an alias associated to the given login is in the catalog delegation of the given pi.
 :)
declare function app:is-pi-valid($login, $pinames, $catalog-name){
    let $coi-aliases := app:get-pi-aliases($login)
    let $test := $pinames ! upper-case(.) = app:get-pi-aliases($login) ! upper-case(.)
    let $test := if($test) then $test
        else
            exists( for $piname in $pinames return user:get-delegations($piname)//delegation[ catalogs[starts-with($catalog-name, .)] and alias=$coi-aliases] )
    return
        $test
};

(:~
 : Get pi names for a given record of specific catalog.
 : / can be used to split multiples pis in the same field
 :)
declare function app:get-pinames($catalog-name as xs:string, $id as xs:string?) as xs:string*
{
    let $pi-colnames := app:get-catalog-pi-name($catalog-name)
    let $primary-key := app:get-catalog-primary-key($catalog-name)
    let $piname := try {
            let $pcol := $pi-colnames ! concat("col=",.)
            let $r := app:sql-query(("catalog="||$catalog-name, $pcol, "id="||$primary-key||":"||$id))
            return
                for $pi in $r?* where $pi return for $e in tokenize($pi, "/") return normalize-space($e)
        } catch * {
            util:log("error", string-join(($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "))
            ,util:log("info" ,"can't find piname for record id="||$id|| " in  "|| $catalog-name || " : pi-colnames="||string-join($pi-colnames, ","))
        }
    let $log := util:log("info" ,"piname for record id="||$id|| " is "|| string-join($piname, ","))
    return
        $piname
};

(:~
 : Check that given user has access to the catalog.
 : Ok if :
 : - the catalog is public
 : - pi of given record is associated to the given login or one if its delegated coi.
 : else the access refused.
 : TODO :
 : - handle mode, test pi before admin ?
 :)
declare function app:has-row-access($catalog-name as xs:string, $id as xs:string, $mode as xs:string)
{
    (: if(app:is-public($catalog-name)) then
        true()
    else
        :)
        let $is-admin := try{ let $t := app:is-admin($catalog-name) return true() } catch * { false() }
        return
            if ($is-admin) then
                true()
            else
                let $pinames := app:get-pinames($catalog-name, $id)
                let $log := util:log("info" ,"pinames for record id="||$id|| " is "|| string-join($pinames, ","))
                return
                    if (app:is-pi-valid(sm:id()//*:username, $pinames, $catalog-name)) then
                        true()
                    else
                        let $reason := "Operation restricted to record's owner(" || string-join($pinames, " / ") || "), delegated users or admins" (: Can we show here the PI value :)
                        return error(
                                xs:QName("app:rest-error"), $reason,
                                app:rest-response(401,$reason)
                            )
};

declare function app:is-authenticated() {
    (: SHOULD we restrict to external authentication or is authenticated is fine ? :)
    if ( sm:is-authenticated() ) then
        true()
    else
        let $reason :="Operation restricted to authenticated users"
        return
            error(
                    xs:QName("app:rest-error"), $reason,
                    app:rest-response(401,$reason)
                )
};

declare function app:is-admin($catalog-name as xs:string) {
    let $always-admin := false()
    (: uncomment next line to simulate admin behaviour :)
    (: let $always-admin := true() :)
    (: ok if catalog-name starts with one group of the authenticated user :)
    return if ( $always-admin or starts-with( $catalog-name, sm:id()//*:group) ) then
        (
            util:log("info", "user "||sm:id()//sm:username||" is admin for " || $catalog-name ),
            true()
        )
    else if (sm:id()//sm:username="spica-qcs@jmmc.fr" ) then
        (
            util:log("info", "user "||sm:id()//sm:username||" is admin for " || $catalog-name ),
            true()
        )
    else if ( $catalog-name="spica_s05" and sm:id()//sm:username="nayeem.ebrahimkutty@oca.eu" ) then
        (
            util:log("info", "user "||sm:id()//sm:username||" is admin for " || $catalog-name ),
            true()
        )
    else
        let $log := util:log("info", "user "||sm:id()//sm:username||" is not admin for " || $catalog-name )
        let $reason := "Operation restricted to admin roles : user "||sm:id()//sm:username||" is not admin for " || $catalog-name
        return
            error(
                xs:QName("app:rest-error"), $reason,
                app:rest-response(401,$reason)
            )
};


(:~
 : Get a VOTABLE from given params querying TAP.
 :
 : @param $params list of parameters according to adql module rules
 : @return a VOTABLE
 :)
declare %private function app:tap-query($params) {
    let $query := adql:build-query($params)
    let $log := util:log("info", "TAP query : " || $query)
    return
        oidb-tap:execute($query)
};

declare function app:rest-response($code, $error-msg){
    app:rest-response($code, $error-msg, (), ())
};

declare function app:rest-response($code, $error-msg, $http-headers, $data){
    (
        <rest:response>
            <http:response status="{$code}">
            { if ($error-msg) then <http:header name="X-HTTP-Error-Description" value="{$error-msg}"/> else () }
            { $http-headers }
            {if($code=401) then <http:header name="Www-Authenticate" value='Basic realm="jmmc account"'/> else ()}
            </http:response>
        </rest:response>
        ,$data (: TODO return an error if no data are given but an error-msg ? :)
    )
};

(:~
 : Get sql result as an array of maps
 :)
declare function app:cast-sql-field($field){
  let $v := data($field)
  return
  try {
        let $type := string($field/@xs:type)
        return
            switch ($type)
                case "xs:string" return
                    string($v)
                case "xs:integer" case "xs:int" return
                    xs:integer($v)
                case "xs:decimal" return
                    xs:decimal($v)
                case "xs:float" case "xs:double" return
                    xs:double($v)
                case "xs:date" return
                    xs:date($v)
                case "xs:dateTime" return
                    xs:dateTime($v)
                case "xs:time" return
                    xs:time($v)
                case "element()" return
                    parse-xml($v)/*
                case "text()" return
                    text { string($v) }
                default return
                    $v

    } catch * {
        $v
    }
};

(:~
 : Get query sql so we can return a json
 :
 : @param $params list of parameters according to adql module rules
 : @return an array of maps ready for json serialisation or an rest response in case of error
 :)
declare %private function app:sql-query($params) {
    try {
        let $query := adql:build-query($params)
        let $log := util:log("info", "SQL query : " || $query)
        let $result := sql:execute(sql:get-jndi-connection(sql-utils:get-jndi-name()), $query, false())

        let $check-result := if ( $result/sql:row and $result/@count > 0) then () (: OK :)
            else if($result/name() = 'sql:result') then
                error(xs:QName("app:sql-not-found"), "no record found", <error><msg>no record found</msg></error>)
            else
                error(xs:QName("app:sql-error"), $result/sql:message, $result) (: we may remove the long stacktrace ?? :)

        return
    (:        [  we may add metadata next to data:)
            for $row in $result/sql:row
                return
                    map:merge (
                        for $field in $row/sql:field return map:entry( $field/@name, app:cast-sql-field($field) )
                    )
    } catch app:sql-not-found {
        app:rest-response(404,$err:description, (), $err:value)
    } catch app:sql-error {
        app:rest-response(400,$err:description, (), $err:value)
    } catch * {
        app:rest-response(400, string-join(($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};

(:~
 : Return pis.
 :
 : @param $catalog-name the name of the catalog to find pi into.
 : @return a list of pis with their login if found in the database and associated .
 :)
(:     %output:media-type("application/json") :)
declare
    %rest:GET
    %rest:path("/catalogs/accounts/{$catalog-name}")
    %rest:produces("application/json")
    %output:method("json")
function app:get-catalog-pis($catalog-name as xs:string) {
    try {
        (: throw error if not authenticated anonymous calls :)
        let $check-auth := app:is-authenticated()

        let $datapis := $user:people-doc//person[alias/@email]
        let $authenticated-pinames := data($datapis[alias[@email=data(sm:id()//*:username)]]/alias)

        let $picols := app:get-catalog-pi-name($catalog-name)
        let $catpis := for $picol in $picols return oidb-tap:execute(adql:build-query(('catalog='||$catalog-name, 'col='||$picol ,'distinct')))

        let $catpis := distinct-values(($authenticated-pinames, $catpis//*:TD) )[string-length(.)>0]

        let $res :=
        map {
            "admins": "TODO",
            "pi" : array {
            for $pi in $catpis order by $pi return
                let $person := $datapis[alias[upper-case(.)=upper-case($pi)]]
                return
                map{ "name":$pi , "login": data($person//@email)[1] , "delegations": app:get-pi-delegations($pi)
                ,"firstname":data($person/firstname), "lastname":data($person/lastname)}
        }}
        return
            $res
    } catch app:rest-error {
        $err:value
    } catch * {
        app:rest-response(400,string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};

(:~
 : Return the catalog list.
 :
 : @return a list of catalogs as keys and their description as values.
 :)
declare
    %rest:GET
    %rest:produces("application/xml")
    %output:media-type("application/json")
    %output:method("json")
    %rest:path("/catalogs")
function app:get-catalogs() {
    try{
        let $res := app:sql-query(("catalog=&quot;TAP_SCHEMA&quot;.tables", "col=table_name", "col=description"))
            return
                try {
                (: reformat maps so client just have to get keys to get list of tables :)
                map:merge ( for $r in $res return map { $r?table_name : $r?description} )
                }catch *{
                    $res
                }
    } catch app:rest-error {
        $err:value
    }
};

(:~
 : Return a catalog given its catalog name (VOTABLE).
 : (limited to 10 firsts, TODO add pagination params : page, perpage)
 :
 : output requested as json could be done ? instead.
 :
 : @param $catalog-name the name of the catalog to find
 : @return a <catalog> element or a 404 status if not found
 :)
declare
    %rest:GET
    %rest:produces("application/xml")
    %output:media-type("application/xml")
    %rest:path("/catalogs/{$catalog-name}")
function app:get-catalog-by-name($catalog-name as xs:string) {
    try {
        let $chech-access := app:has-access($catalog-name, "r--")
        return
            app:tap-query(("catalog=" || $catalog-name, "limit=10"))
    }catch app:rest-error {
        $err:value
    } catch * {
        app:rest-response( 400, string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};

(:~
 : Return a catalog description given a catalog name.
 : TODO return 404 if not found
 :
 : @param $catalog-name the name of the catalog to find
 : @return a json serialized record.
 :)
declare
    %rest:GET
    %rest:path("/catalogs/meta/{$catalog-name}")
    %output:media-type("application/json")
    %output:method("json")
function app:get-catalog-meta($catalog-name as xs:string) {
    try {
        app:get-metadata($catalog-name)
    } catch * {
        app:rest-response( 400, string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};


(:~
 : Return a catalog record given a catalog name and record ID.
 :
 : @param $catalog-name the name of the catalog to find
 : @param $id the id of the catalog record to find
 : @return a <catalog> element or a 404 status if not found
 :     %rest:query-param("id", "{$id}")
 :)
declare
    %rest:GET
    %rest:path("/catalogs/{$catalog-name}/{$id}")
    %output:media-type("application/json")
    %output:method("json")
function app:get-catalog-row($catalog-name as xs:string, $id as xs:string) {
    try{
(:        let $check-access := app:has-row-access($catalog-name, $id, "r--"):)
        let $primary-key := app:get-catalog-primary-key($catalog-name)
        return
            app:sql-query(("catalog=" || $catalog-name, "id="||$primary-key||":"||$id))
    } catch app:rest-error {
        $err:value
    }
};

(:~
 : Return a catalog record given a catalog name and record ID.
 :
 : @param $catalog-name the name of the catalog to find
 : @param $id the id of the catalog record to find
 : @param $key the column name of the catalog record to find
 : @return a json element for given cell.
 :)
declare
    %rest:GET
    %rest:path("/catalogs/{$catalog-name}/{$id}/{$key}")
    %output:media-type("application/json")
    %output:method("json")
function app:get-catalog-cell($catalog-name as xs:string, $id as xs:integer, $key as xs:string) {
    let $id-col-name := app:get-catalog-primary-key($catalog-name)
    return
        app:sql-query(("catalog=" || $catalog-name, "id="||$id-col-name||":"||$id, "col="||$key))
};

declare function app:map-filter($map as map(*), $removed-keys as xs:string*){
    map:merge( map:for-each( $map, function ($k,$v) { map:entry($k, $v)[not($k=$removed-keys)] } ) )
};

(:~
 : Return a sql fragment to be used inside an SQL UPDADE statement.
 : @param $params map of properties to be updated.
 :)
declare function app:get-row-set-expr($params){
(:  :    let $log:= util:log("info", $params)
    return
   :)
    string-join(
        map:for-each($params, function($k, $v){
            if(exists($v)) then $k || "='" || sql-utils:escape($v) || "'" else $k || "=null"
        })
        ,', '
    )
};


(:~
 : Return a json fragment to describe given values.
 : @param $params map of properties to be described.
 :)
declare function app:get-row-json-expr($params){
    string-join( ("", map:for-each($params, function($k, $v){ "&quot;" || $k || "&quot;:&quot;" || replace(sql-utils:escape($v),"&quot;","\\&quot;") || "&quot;" }) ) ,', ' )
};

(:~
 : Prepare an update statement plus associated history statement if table changes must be recorded.
 :)
declare function app:get-row-update-statement($catalog-name, $values) as xs:string*
{
    let $array := if ($values instance of map()) then array { $values } else $values

    for $values in $array?*
        (: get logic columns :)
        let $id-col-name := app:get-catalog-primary-key($catalog-name)
        let $id := $values($id-col-name)
        let $lastmods-col-name := app:get-catalog-lastmods($catalog-name)
        (: build set expr filtering some columns:)
        (: TODO add picolumns (excepted for admin?) :)
        let $values-to-update := app:map-filter($values, ($id-col-name, $lastmods-col-name))
        let $set-expr := app:get-row-set-expr($values-to-update)
        (: check we have enough to work on :)
        let $check-set := if(string-length($set-expr)>0) then () else error(xs:QName("app:missing-col"), "no value to update")
        let $check-primary-key := if($id) then () else error(xs:QName("app:missing-key"), $id-col-name || " is mandatory")

        let $update-statement := string-join( ( "UPDATE", $catalog-name, "SET", $set-expr, "WHERE", $id-col-name || "='" || $id || "'" ), ' ')
        (: prepare json like history :)
        let $history-statement := if($lastmods-col-name) then
            let $history-prefix := '[{"history":"API"}'
            let $history-json := app:get-row-json-expr($values-to-update)
            let $history-info := <info>{{"utc":"{current-dateTime()}", "by":"{sm:id()//sm:username}"{$history-json}}}</info>
            let $check-json := parse-json($history-info)
            return
            <statement>
            UPDATE {$catalog-name}
            SET
              {$lastmods-col-name} = CASE
              WHEN {$lastmods-col-name} IS NULL OR {$lastmods-col-name} = '' THEN
                '{$history-prefix},{$history-info} ]'
              ELSE
                REPLACE({$lastmods-col-name}, '{$history-prefix}','{$history-prefix},{$history-info}')
              END
            WHERE
              {$id-col-name}='{$id}'
            </statement>
            else
                ()
        return
            ( $update-statement, $history-statement )
};

declare function app:get-row-insert-statement($catalog-name as xs:string, $array as array(*)) as xs:string*
{
    for $values in $array?*
        let $id-col-name := app:get-catalog-primary-key($catalog-name)
        let $keys := map:keys($values)
        let $check-value := if(map:size($values)>0) then () else error(xs:QName("app:missing-col"), "no value to insert")
        let $columns := "( " || string-join($keys, ', ') || " )"
        let $vals := "( " || string-join( ( for $key in $keys return "'" || sql-utils:escape($values($key)) || "'"), ', ') || " )"

        return
            string-join( ( "INSERT INTO", $catalog-name, $columns, "VALUES", $vals ,    "RETURNING "|| $id-col-name ), ' ')
};



(:~
 : Update a single catalog record for a given id with values provided by given json content.
 : eg: { "target_priority_pi": 2, "target_spica_mode": "ABCD" }
 :
 : @param $catalog-name the catalog name to update
 : @param $id the id of the catalog record to update
 : @param $catalog-entry record values to update
 : @return ignore, see HTTP status code
 :)
declare
    %rest:PUT("{$catalog-entry}")
    %rest:path("/catalogs/{$catalog-name}/{$id}")
    %rest:consumes("application/json")
    %rest:produces("application/json")
    %output:method("json")
function app:update-row($catalog-name as xs:string, $id as xs:string, $catalog-entry) {
    let $primary-key := app:get-catalog-primary-key($catalog-name)
    let $json := parse-json(util:base64-decode($catalog-entry))
    let $json := if ($json instance of xs:string) then parse-json($json) else $json (: We can get the json or its string serialization :)

    (: TODO check if primary-key is present in payload :)
    return
        (: normalize argument as a multirow update :)
        app:update-catalog($catalog-name, array { map:merge((map {$primary-key:$id} , $json)) })
};


(:~
 : Update multiple catalog records looking at given ids and their values provided by given json content.
 : payload is considered valid if :
 :  - all elements of the array have a single id
 :  - all ids are distincts
 : we expect to receive non duplicated keys in the same json element else only one will be considered
 :
 : @param $catalog-entry record values to update
 : @param $catalog-doc the new data for the catalog
 : @return ignore, see HTTP status code
 :)
declare
    %rest:PUT("{$catalog-entries}")
    %rest:path("/catalogs/{$catalog-name}")
    %rest:consumes("application/json")
     %rest:produces("application/json")
    %output:method("json")
function app:update-rows($catalog-name as xs:string, $catalog-entries) {
    let $json := parse-json(util:base64-decode($catalog-entries))
    let $json := if ($json instance of xs:string) then parse-json($json) else $json (: We can get the json or its string serialization :)
    return
        app:update-catalog($catalog-name, $json)
};


(:~
 : Update multiple catalog records looking at given ids and their values provided by given json content.
 : payload is considered valid if :
 :  - all elements of the array have a single id
 :  - all ids are distincts
 : we expect to receive non duplicated keys in the same json element else only one will be considered
 :
 : @param $catalog-entry record values to update
 : @param $json the new data for the catalog
 : @return ignore, see HTTP status code
 :)
declare function app:update-catalog($catalog-name as xs:string, $values as array(*) ) {
    let $connection-handle := sql:get-jndi-connection(sql-utils:get-jndi-name())
    return
    try {
        let $check-access := app:has-access($catalog-name, "r--") (: TODO replace by has rows access :)

        let $id-col-name := app:get-catalog-primary-key($catalog-name)
        let $ids := for $row in $values?* return $row($id-col-name)
        let $log := util:log("info", "ids to be updated : "|| string-join($ids))
        let $check := for $id in $ids  return app:has-row-access($catalog-name, $id, "r--") (: TODO think about grouping for optimisation :)
        let $sql-statements := app:get-row-update-statement($catalog-name, $values)

        let $begin := sql:execute($connection-handle, "START TRANSACTION", false())

        let $results:=
            for $s in $sql-statements
                let $result := sql:execute($connection-handle, $s, false())
                (:
                let $log := util:log("info", "SQL: " || $s)
                let $log := util:log("info", "RESULT: " || serialize($result))
                :)
                return
                    if ($result/@updateCount=0)
                    then
                        let $reason := 'Failed to update : record not found.'||" STATEMENT: "||$s
                        return
                            error(xs:QName('app:rest-error'), $reason, app:rest-response(404 (: Not Found :) , $reason , (), () ) )
                    else if( $result[name() = 'sql:exception'] )
                    then
                        error(xs:QName('sql:exception'), $result//sql:message||" STATEMENT: "||$s  )
                    else
                        $result
        return
            if ($results/@updateCount >= 1) then
                let $end   := sql:execute($connection-handle, "COMMIT", false())
                let $close := sql:close-connection($connection-handle)
                return
                    app:rest-response(204 (: No Content :) ,(),(),())
            else
                let $end :=sql:execute($connection-handle, "ROLLBACK", false())
                let $close := sql:close-connection($connection-handle)
                return
                    app:rest-response(400 (: Bad Request :) , 'Failed to update records.', (), () )
    } catch app:rest-error {
        let $end :=sql:execute($connection-handle, "ROLLBACK", false())
        let $close := sql:close-connection($connection-handle)
        return
            $err:value
    } catch sql:exception {
        let $end :=sql:execute($connection-handle, "ROLLBACK", false())
        let $close := sql:close-connection($connection-handle)
        return
            app:rest-response(400 (: Bad Request :), 'Failed to update records : ' || string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ) ), (), () )
    }catch * {
        let $end :=sql:execute($connection-handle, "ROLLBACK", false())
        let $close := sql:close-connection($connection-handle)
        return
            app:rest-response(400 (: Bad Request :), string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", "), (), ())
    }
};



(:~
 : Add records looking at given json content.
 : payload is considered valid if :
 :  - all elements of the array have a required columns
 :
 : @param $catalog-entry record values to update
 : @param $catalog-doc the new data for the catalog
 : @return ids of new records or error, see HTTP status code
 :)
declare
    %rest:POST("{$catalog-entries}")
    %rest:path("/catalogs/{$catalog-name}")
    %rest:consumes("application/json")
     %rest:produces("application/json")
    %output:method("json")
function app:post-catalog($catalog-name as xs:string, $catalog-entries) {
    let $connection-handle := sql:get-jndi-connection(sql-utils:get-jndi-name())
    return
    try {
        if (not(app:is-admin($catalog-name))) then app:rest-response(401, "Please login as admin", (), ())
        else

        let $json-txt := util:base64-decode($catalog-entries)
        let $log := util:log('info', "JSON for post : "|| $json-txt)
        let $json := parse-json($json-txt)
        let $values := $json

        let $begin := sql:execute($connection-handle, "START TRANSACTION", false())
        let $sql-statements := app:get-row-insert-statement($catalog-name, $values)

        let $results:=
            for $s in $sql-statements
                let $log := util:log("info", "SQL: " || $catalog-name || ":" || $s)
                let $result := sql:execute($connection-handle, $s, false())
                return
                    $result (: TODO : throw an error if no record updated :)
(:                         and $result/@updateCount = 1) then:)

        let $end   := sql:execute($connection-handle, "COMMIT", false())
        let $close := sql:close-connection($connection-handle)

        let $result := map{ app:get-catalog-primary-key($catalog-name) : data($results) }

        return
            if (exists($result)) then (: TODO check for errors :)
                (: rows inserted successfully :)
                app:rest-response(200, () ,(), $result)
                (: TODO COMMIT :)
            else if ($result/name() = 'sql:exception') then
                app:rest-response(400 (: Bad Request :) , 'Failed to insert records : ' || data($result//sql:message), (), ())
                (: TODO ROLLBACK :)
            else
                app:rest-response(404 (: Not Found :) , 'Failed to insert records.', (), () )
                (: TODO ROOLBACK :)
    } catch sql:exception {
        let $end :=sql:execute($connection-handle, "ROLLBACK", false())
        let $close := sql:close-connection($connection-handle)
        let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module||"(L"||$err:line-number||",C"||$err:column-number||")" ), ", ")
        return
            app:rest-response(400 (: Not Found :), $msg,  (), ())
    }catch * {
        let $end :=sql:execute($connection-handle, "ROLLBACK", false())
        let $close := sql:close-connection($connection-handle)
        let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module||"(L"||$err:line-number||",C"||$err:column-number||")" ), ", ")
        return
            app:rest-response(400, $msg, (), ())
    }
};


(:~
 : test endpoint
 :)
declare
    %rest:GET
    %rest:path("/catalogs/status")
    %rest:produces("application/json")
    %output:method("json")
function app:status() {
    let $all-aliases := $user:people-doc//alias
    let $count-aliases := count($all-aliases)
    return
    array{map{
(:        "version" : $config:expath-descriptor//@version:)
(:        ,"status" : data($config:repo-descriptor//status):)
        "login" : data(sm:id()//*:username)
        ,"groups" : string-join(sm:id()//*:group, ", ")
        ,"pi-aliases" : string-join(app:get-pi-aliases(sm:id()//*:username), ", ")
        (: ,"oidb-config": $oidb-config:data-root :)
        (: ,"jndi-name" : sql-utils:get-jndi-name() :)
        ,"nb_people" : count($user:people-doc//person)
        ,"nb_aliases" : $count-aliases
        ,"uniq_aliases" : count(distinct-values($all-aliases)) = $count-aliases
        ,"nb_people_with_delegation" : count($user:people-doc//person[.//delegation/*])
    }}
};

(: -------------------------------
 : UNFINISHED BELOW ....
 : -------------------------------
 :)


(:~
 : TODO? Delete the catalog with the given ID from the database.
 : @param $id the id of the catalog to delete
 : @return ignore, see HTTP status code
 :)
declare
(:    %rest:DELETE:)
(:    %rest:path("/catalogs/{$id}"):)
function app:delete-catalog($id as xs:string) {
    let $status := try {
            let $do := <todo><or-not/></todo>
            return 204 (: No Content :)
        } catch app:unknown {
            404 (: Not Found :)
        } catch app:error {
            400 (: Bad Request :)
        } catch app:unauthorized {
            401 (: Unauthorized :)
        } catch * {
            500 (: Internal Server Error :)
        }
    return app:rest-response($status, (), (), ())
};
