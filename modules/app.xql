xquery version "3.1";

module namespace app="http://exist.jmmc.fr/catalogs/templates";

import module namespace templates="http://exist-db.org/xquery/templates" ;
import module namespace config="http://exist.jmmc.fr/catalogs/config" at "config.xqm";

import module namespace sql-utils="http://apps.jmmc.fr/exist/apps/oidb/sql-utils" at "../../oidb/modules/sql-utils.xql";
import module namespace log="http://apps.jmmc.fr/exist/apps/oidb/log" at "../../oidb/modules/log.xqm";
import module namespace adql="http://apps.jmmc.fr/exist/apps/oidb/adql" at "../../oidb/modules/adql.xqm";
import module namespace tap="http://apps.jmmc.fr/exist/apps/oidb/tap" at "../../oidb/modules/tap.xqm";

import module namespace sql="http://exist-db.org/xquery/sql";

import module namespace http = "http://expath.org/ns/http-client";
declare namespace output = "http://www.w3.org/2010/xslt-xquery-serialization";
declare namespace rest="http://exquery.org/ns/restxq";

declare namespace xsns="http://www.w3.org/2001/XMLSchema";


(: 
 : - try not to return 500 errors and prefer 400 so the client will consume and not loop over with retries
 : - check authentication for every sensible operations :
 :     - read protected data
 :     - modify content
 : TODO add a version on api ?
 : TODO separate low level code from api ? move code in catalogs anyway...
 :)

(:~
 : This is a sample templating function. It will be called by the templating module if
 : it encounters an HTML element with an attribute: data-template="app:test" or class="app:test" (deprecated). 
 : The function has to take 2 default parameters. Additional parameters are automatically mapped to
 : any matching request or function parameter.
 : 
 : @param $node the HTML node with the attribute which triggered this call
 : @param $model a map containing arbitrary data - used to pass information between template calls
 :)
declare function app:test($node as node(), $model as map(*)) {
    <div>
        <h3>Tables</h3>
        <div>
            <table class="table table-rows">
            {
                map:for-each( app:get-catalogs(), function ($k,$v) { <tr><td>{$k}</td><td>{$v}</td></tr> } )
            }
            </table>
        </div>
    </div>
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
        tap:execute($query)
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
                error(xs:QName("app:sql-error"), $result/sql:message, $result)
        
        return
    (:        [  we may add metadata next to data:)
            for $row in $result/sql:row 
                return 
                    map:merge (
                        for $field in $row/sql:field return map:entry( $field/@name, app:cast-sql-field($field) )
                    )
    
    } catch app:sql-not-found {
        (
            <rest:response>
                <http:response status="404">
                    <http:header name="X-HTTP-Error-Description" value="{$err:description}"/>
                </http:response>
            </rest:response>,
            $err:value 
        )
    } catch app:sql-error {
        (
            <rest:response>
                <http:response status="400">
                    <http:header name="X-HTTP-Error-Description" value="{$err:description}"/>
                </http:response>
            </rest:response>,
            $err:value (: we may remove the long stacktrace ?? :)
        )
    } catch * {
            let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ")
            let $log := util:log("error",$msg)
            return 
                <rest:response>
                    <http:response status="400">
                        <http:header name="X-HTTP-Error-Description" value="{$msg}"/>
                    </http:response>
                </rest:response>
    }
};

(:~
 : Return pis.
 : 
 : @param $catalog-name the name of the catalog to find pi into.
 : @return a list of pis with their login if found in the database.
 :)
declare
    %rest:GET
    %rest:produces("application/json")
    %output:media-type("application/json")
    %output:method("json")
    %rest:path("/catalogs/accounts/{$catalog-name}")
function app:get-catalog-pis($catalog-name as xs:string) {
    (: reject anonymous calls :)
    if (sm:is-authenticated()) then 
    try {
        (: TODO generalise : hardcoded for spica and oidb : prefer to look at catalog metadata :)    
        let $picol := if (starts-with($catalog-name, "spica")) then "target_piname" else "datapi"
        
        let $catpis := tap:execute(adql:build-query(('catalog='||$catalog-name,'col='||$picol,'distinct')))
        
        let $datapis := doc("/db/apps/oidb-data/people/people.xml")//person[alias/@email]
        let $res :=
        <res>
            {
                for $pi in data($catpis//*:TD) return 
                    <pi>
                        <name>{$pi}</name>
                        {for $datapi in $datapis[alias[upper-case(.)=upper-case($pi)]] return <login>{string(($datapi//@email)[1])}</login> }
                    </pi>
            }
        </res>
        return 
            $res    
    } catch * {
        <rest:response><http:response status="400"/></rest:response>,
        map {
            "error": string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ")
        }
    }
    else
        (
            <rest:response><http:response status="401"><http:header name="Www-Authenticate" value='Basic realm="jmmc account"'/></http:response></rest:response>,
            map { "error": "please send authentication" }
        )
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
    let $res := app:sql-query(("catalog=&quot;TAP_SCHEMA&quot;.tables", "col=table_name", "col=description"))
    return
        try {
            (: reformat maps so client just have to get keys to get list of tables :)
            map:merge ( for $r in $res return map { $r?table_name : $r?description} )
        }catch *{
            $res
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
        app:tap-query(("catalog=" || $catalog-name, "limit=10"))
    } catch * {
        let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ")
        let $log := util:log("error",$msg)
        return 
            <rest:response>
                <http:response status="500">
                    <http:header name="X-HTTP-Error-Description" value="{$msg}"/>
                </http:response>
            </rest:response>
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
        (: TODO move this part in a common cached part that extract all catalog metadata :)
        let $vot := app:tap-query(("catalog=" || $catalog-name, "limit=1"))
        return 
            <meta>TODO</meta>
    } catch * {
        let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ")
        let $log := util:log("error",$msg)
        return 
            <rest:response><http:response status="500">
                    <http:header name="X-HTTP-Error-Description" value="{$msg}"/>
                    <error>{$msg}</error>
                </http:response>
            </rest:response>
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
function app:get-catalog-row($catalog-name as xs:string, $id as xs:integer) {
    app:sql-query(("catalog=" || $catalog-name, "id="||$id))
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
    app:sql-query(("catalog=" || $catalog-name, "id="||$id, "col="||$key))
};

(:~
 : Return a catalog record given a catalog name and record ID.
 : 
 : @param $catalog-name the name of the catalog to find
 : @param $id the id of the catalog record to find
 : @return a json serialized record.
 :)
declare
    %rest:GET
    %rest:path("/catalogs/{$catalog-name}/{$id}")
    %output:media-type("application/json")
    %output:method("json")
function app:get-catalog-row($catalog-name as xs:string, $id as xs:integer) {
        app:sql-query(("catalog=" || $catalog-name, "id="||$id))
};

declare function app:get-row-update-statement($catalog-name, $values) as xs:string* 
{
    let $array := if ($values instance of map()) then array { $values } else $values

    for $values in $array?*
        let $id := $values?id 
        (:    let $has-id := if ( empty($id) ) then error("id key must be present for update") else ():)
        
        (: build set expr filtering ID value :)
        let $set-expr := string-join( map:for-each($values, function($k, $v){ if ($k != 'id' ) then $k || "='" || sql-utils:escape($v) || "'" else () }) ,', ' )
        let $check-set := if(string-length($set-expr)>0) then () else error(xs:QName("app:missing-col"), "no value to update")
        return
        string-join( ( "UPDATE", $catalog-name, "SET", $set-expr, "WHERE id='" || $id || "'" ), ' ')
};
 

(:~
 : Update a single catalog record for a given id with values provided by given json content.
 : eg: { "target_priority_pi": 2, "target_spica_mode": "ABCD" }
 : 
 : @param $catalog-entry record values to update
 : @param $catalog-doc the new data for the catalog
 : @param $id the id of the catalog record to update
 : @return ignore, see HTTP status code
 :)
declare
    %rest:PUT("{$catalog-entry}")
    %rest:path("/catalogs/{$catalog-name}/{$id}")
    %rest:consumes("application/json")
    %rest:produces("application/json")
    %output:method("json")
function app:put-catalog($catalog-name as xs:string, $id as xs:string, $catalog-entry) {
    
    (:  TODO check for permissions : general access then per row :)
    let $log := util:log('info', "user is : " || serialize( sm:id() ) ) 
    
    let $resp := (: must contains (status-code, optionnal-error-message) :) 
        try {
            if (not(sm:is-authenticated())) then (401, "Please login") 
            else
                
            let $connection-handle := sql:get-jndi-connection(sql-utils:get-jndi-name())
           
            let $json := parse-json(util:base64-decode($catalog-entry))
(:            let $meta := map { "lastModDate":current-dateTime() , "lastModAuthor": sm:id()//sm:username  }:)
(:            let $values := map:merge(($json, $meta)):)
 
            let $values := map:merge(( $json , map {"id":$id} ))
            let $sql-statement := app:get-row-update-statement($catalog-name, $values)

            let $log := util:log("info", "updating " || $catalog-name || "/" || $id || ":" || $sql-statement)
    
            let $result := if( true() ) then (: at present time execution must be performed here to avoir pool starvation :)
                    sql:execute($connection-handle, $sql-statement, false())
                else
                    let $log := util:log("info", "using given handle for sql-utils :" || $connection-handle )
                    return
                        sql-utils:execute($connection-handle, $sql-statement, false())

            return
                if ($result/name() = 'sql:result' and $result/@updateCount = 1) then
                    (: row updated successfully :)
                    (204 (: No Content :) ,())
                else if ($result/name() = 'sql:exception') then
                    (400 (: Not Found :) , 'Failed to update record ' || $id || ' : ' || data($result//sql:message))
                else
                    (404 (: Bad Request :) , 'Failed to update record ' || $id || '.' || $connection-handle )
                    
        } catch * {
            let $msg := string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ") 
            return 
                ( 400 (: Internal Server Error :) , $msg, util:log("error", $msg) )
        }
        
    return 
        (
        <rest:response>
            <http:response status="{ $resp[1] }">
                {
                    if ( empty($resp[2]) ) then ()
                    else
                        <http:header name="X-HTTP-Error-Description" value="{$resp[2]}"/>
                }
            </http:response>
        </rest:response>
        , map { "error" : $resp[2], "log": "request performed by "||serialize( sm:id() )  }
        )
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
function app:put-catalog($catalog-name as xs:string, $catalog-entries) {
    
    (:  TODO check for permissions : general access then per row :)
    let $log := util:log('info', "user is : " || serialize( sm:id() ) ) 
    
    let $resp := (: must contains (status-code, optionnal-error-message) :) 
        try {
            if (not(sm:is-authenticated())) then (401, "Please login") 
            else
            
            let $json := parse-json(util:base64-decode($catalog-entries))
            let $values := $json
            
            (: TODO start transaction :)
            
            let $sql-statements := app:get-row-update-statement($catalog-name, $values)
            
            let $connection-handle := sql:get-jndi-connection(sql-utils:get-jndi-name())
            let $results:= 
                for $s in $sql-statements
                    let $log := util:log("info", "updating " || $catalog-name || ":" || $s)
                    let $result := sql:execute($connection-handle, $s, false())
                    return
                        $result (: TODO : throw an error if no record updated :)
                
            (: TODO analyse whole results so we can commit :)
            (: hack : returning first faulty one :)
            let $result := ($results[name() = 'sql:exception'] | $results[not(name() = 'sql:exception')])[1]
            let $result := $results[position()  = last()]
            
            return
                if ($result/name() = 'sql:result' and $result/@updateCount = 1) then
                    (: row updated successfully :)
                    (204 (: No Content :) ,())
                    (: TODO COMMIT :)
                else if ($result/name() = 'sql:exception') then
                    (400 (: Not Found :) , 'Failed to update records : ' || data($result//sql:message))
                    (: TODO ROLLBACK :)
                else
                    (404 (: Bad Request :) , 'Failed to update records.' )
                    (: TODO ROOLBACK :)
        } catch sql:exception {
            (400 (: Not Found :), 'Failed to update records : ' || string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ) ) , util:log("error", "sql:exception "))
        }catch * {
            
            (: TODO ROLLBACK :)
            
            let $msg := "can't update : "|| string-join( ($err:code, $err:description, $err:value, " module: ", $err:module, "(", $err:line-number, ",", $err:column-number, ")" ), ", ") 
            return 
                ( 500 (: Internal Server Error :) , $msg, util:log("error", $msg) )
                
        }
        
    return 
        <rest:response>
            <http:response status="{ $resp[1] }">
                {
                    if ( empty($resp[2]) ) then ()
                    else
                    <http:header name="X-HTTP-Error-Description" value="{$resp[2]}"/>
                }
            </http:response>
        </rest:response>
};


(: -------------------------------
 : UNFINISHED BELOW but could be reused
 :)

(:~
 : Push one or more catalogs records into the database.
 : TODO ??
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
    return <rest:response><http:response status="{ $status }"/></rest:response>
};

