import type { Collection, PublicURL } from "ente-media/collection";
import { publicAlbumShareURL } from "ente-photos-wasm";
import { useEffect, useMemo, useState } from "react";

export const resolvePublicLinkURL = async (
    publicURL: string,
    collectionKey: string,
    customDomain: string | undefined,
) => {
    const url = new URL(await publicAlbumShareURL(publicURL, collectionKey));
    if (customDomain) url.host = customDomain;
    return url.href;
};

export const usePublicLinkURL = (
    collection: Pick<Collection, "id" | "key">,
    publicURL: PublicURL | undefined,
    customDomain?: string,
) => {
    const url = publicURL?.url;
    const { id, key } = collection;
    const input = useMemo(
        () => ({ id, key, url, customDomain }),
        [id, key, url, customDomain],
    );
    const [result, setResult] = useState<
        | { input: typeof input; resolvedURL?: string; error?: unknown }
        | undefined
    >();

    useEffect(() => {
        if (!input.url) return;
        let cancelled = false;

        void resolvePublicLinkURL(input.url, input.key, input.customDomain)
            .then((resolvedURL) => {
                if (!cancelled) setResult({ input, resolvedURL });
            })
            .catch((error: unknown) => {
                if (!cancelled) setResult({ input, error });
            });

        return () => {
            cancelled = true;
        };
    }, [input]);

    const currentResult = result?.input === input ? result : undefined;
    return {
        resolvedURL: currentResult?.resolvedURL,
        isLoading: Boolean(url) && !currentResult,
        error: currentResult?.error,
    };
};
