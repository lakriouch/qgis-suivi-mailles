CREATE OR REPLACE FUNCTION mailles_cen.create_maillage(
    p_code_site_mere text,
    p_maille integer
)
RETURNS TABLE (
    nb_mailles_calculees integer,
    nb_mailles_inserees integer,
    nb_liens_site_maille_crees integer
)
LANGUAGE plpgsql
AS $function$
BEGIN

    -- Vérification de la taille de maille
    IF p_maille NOT IN (5, 10, 25, 50, 100) THEN
        RAISE EXCEPTION
        'Taille de maille invalide : %. Valeurs acceptées : 5, 10, 25, 50, 100.',
        p_maille;
    END IF;

    -- Vérification du site
    IF NOT EXISTS (
        SELECT 1
        FROM bd_site_cen.site_cen sc
        WHERE sc.code_site_mere = p_code_site_mere
    ) THEN
        RAISE EXCEPTION
        'Aucun site trouvé pour code_site_mere = %',
        p_code_site_mere;
    END IF;

    RETURN QUERY
    WITH sites AS (
        SELECT
            sc.codesitep,
            ST_Buffer(gs.geom, p_maille * 2) AS geom_buffer
        FROM bd_site_cen.site_cen sc
        JOIN bd_site_cen.geo_site gs
            ON gs.codesitep = sc.codesitep
        WHERE sc.code_site_mere = p_code_site_mere
    ),

    mailles_calculees AS (
        SELECT DISTINCT
            s.codesitep,

            ST_MakeEnvelope(
                ST_XMin(g.geom) + (i * p_maille),
                ST_YMin(g.geom) + (j * p_maille),
                ST_XMin(g.geom) + (i * p_maille) + p_maille,
                ST_YMin(g.geom) + (j * p_maille) + p_maille,
                2154
            ) AS geom,

            g.code1km || '_' || p_maille || 'm_e' ||
            lpad(((floor(ST_XMin(g.geom) + (i * p_maille))::int % 1000)::text), 3, '0') ||
            'n' ||
            lpad(((floor(ST_YMin(g.geom) + (j * p_maille))::int % 1000)::text), 3, '0')
            AS code_maille,

            g.code10km,
            g.code1km,
            g.code5km,
            g.code_500m

        FROM sites s
        JOIN fdw."500x500m_hdf" g
            ON g.geom && s.geom_buffer
           AND ST_Intersects(s.geom_buffer, g.geom)

        CROSS JOIN generate_series(0, (500 / p_maille - 1)) AS i
        CROSS JOIN generate_series(0, (500 / p_maille - 1)) AS j

        WHERE ST_Intersects(
            s.geom_buffer,
            ST_MakeEnvelope(
                ST_XMin(g.geom) + (i * p_maille),
                ST_YMin(g.geom) + (j * p_maille),
                ST_XMin(g.geom) + (i * p_maille) + p_maille,
                ST_YMin(g.geom) + (j * p_maille) + p_maille,
                2154
            )
        )
    ),

    mailles_uniques AS (
        SELECT DISTINCT ON (code_maille)
            geom,
            code_maille,
            code10km,
            code1km,
            code5km,
            code_500m
        FROM mailles_calculees
        ORDER BY code_maille
    ),

    insert_mailles AS (
        INSERT INTO mailles_cen.maille_sitescen
        (
            geom,
            code_maille,
            code10km,
            code1km,
            code5km,
            code_500m,
            maille
        )
        SELECT
            geom,
            code_maille,
            code10km,
            code1km,
            code5km,
            code_500m,
            p_maille
        FROM mailles_uniques
        ON CONFLICT (code_maille) DO NOTHING
        RETURNING id, code_maille
    ),

    toutes_les_mailles AS (
        SELECT DISTINCT
            m.id,
            m.code_maille
        FROM mailles_cen.maille_sitescen m
        JOIN mailles_uniques mu
            ON mu.code_maille = m.code_maille
    ),

    insert_site_maille AS (
        INSERT INTO mailles_cen.site_maille
        (
            codesitep,
            id_maille,
            code_maille,
            taille_maille,
            date_generation
        )
        SELECT DISTINCT
            mc.codesitep,
            tm.id,
            mc.code_maille,
            p_maille,
            now()
        FROM mailles_calculees mc
        JOIN toutes_les_mailles tm
            ON tm.code_maille = mc.code_maille
        ON CONFLICT (codesitep, id_maille, taille_maille) DO NOTHING
        RETURNING id_site_maille
    )

    SELECT
        (SELECT count(*)::integer FROM mailles_uniques),
        (SELECT count(*)::integer FROM insert_mailles),
        (SELECT count(*)::integer FROM insert_site_maille);

END;
$function$;


SELECT
    event_object_schema,
    event_object_table,
    trigger_name,
    action_timing,
    event_manipulation,
    action_statement
FROM information_schema.triggers
WHERE event_object_schema IN ('mailles_cen', 'suivi_cen', 'bd_site_cen')
ORDER BY event_object_schema, event_object_table, trigger_name;


toutes_les_mailles AS (
    SELECT
        im.id,
        im.code_maille
    FROM insert_mailles im

    UNION

    SELECT DISTINCT
        m.id,
        m.code_maille
    FROM mailles_cen.maille_sitescen m
    JOIN mailles_uniques mu
        ON mu.code_maille = m.code_maille
),


  toutes_les_mailles AS (
        -- Mailles nouvellement insérées pendant cet appel
        SELECT
            im.id,
            im.code_maille
        FROM insert_mailles im
        UNION
        
        -- Mailles qui existaient déjà avant cet appel
        SELECT DISTINCT
            m.id,
            m.code_maille
        FROM mailles_cen.maille_sitescen m
        JOIN mailles_uniques mu
            ON mu.code_maille = m.code_maille
    ),
